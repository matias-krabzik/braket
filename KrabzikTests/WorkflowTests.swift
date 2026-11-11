@testable import Krabzik
import XCTest

@MainActor final class WorkflowTests: XCTestCase {
    func testConnectingPortsUpdatesBranchesAndRejectsCycles() throws {
        var flow = Workflow.first()
        let script = try XCTUnwrap(flow.nodes.first(where: { $0.kind == .script }))
        let decision = try XCTUnwrap(flow.nodes.first(where: { $0.kind == .decision }))
        let ends = flow.nodes.filter { $0.kind == .end }
        XCTAssertTrue(flow.connect(from: decision.id, isNo: true, to: ends[0].id))
        XCTAssertEqual(flow.nodes.first(where: { $0.id == decision.id })?.no, ends[0].id)
        XCTAssertFalse(flow.connect(from: decision.id, isNo: false, to: script.id))
        XCTAssertFalse(flow.connect(from: script.id, isNo: true, to: ends[1].id))
        XCTAssertFalse(flow.connect(from: ends[0].id, isNo: false, to: script.id))
        XCTAssertFalse(flow.connect(from: script.id, isNo: false, to: flow.nodes[0].id))
    }

    func testThreeTriggersCanShareAFlowWithoutIncomingConnections() throws {
        var flow = Workflow.first()
        let event = WorkflowNode(kind: .event, title: "Evento", x: 70, y: 320)
        let schedule = WorkflowNode(kind: .schedule, title: "Horario", x: 70, y: 420)
        flow.nodes.append(contentsOf: [event, schedule])
        let file = WorkflowFile(workflows: [flow])
        XCTAssertNoThrow(try file.validate())
        let restored = try JSONDecoder().decode(WorkflowFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(restored.workflows[0].nodes.filter { $0.kind.isTrigger }.count, 3)

        flow.nodes[0].next = event.id
        XCTAssertThrowsError(try WorkflowFile(workflows: [flow]).validate())
    }

    func testEventAndScheduleTriggersReturnOKWhenTested() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        let finalNode = try XCTUnwrap(model.selected?.nodes.first(where: { $0.kind == .end }))
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        for kind in [WorkflowKind.event, .schedule] {
            let trigger = WorkflowNode(kind: kind, title: kind.title, x: 70, y: 300, next: finalNode.id)
            model.file.workflows[0].nodes.append(trigger)
            model.run(workspace: workspace, root: root, runner: runner, trusted: true, trigger: kind)
            let deadline = Date().addingTimeInterval(5)
            while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
            XCTAssertFalse(model.isRunning)
            XCTAssertEqual(model.visited[trigger.id], .exited(0))
        }
    }

    func testWorkflowFileRejectsExternalOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        model.save()
        let path = try XCTUnwrap(model.selected.flatMap { model.storageURL(for: $0) })
        XCTAssertTrue(path.path.hasSuffix(".flow.json"))
        let external = Data("external change".utf8)
        try external.write(to: path)
        model.save()
        XCTAssertFalse(model.error.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), external)
    }

    func testFirstFlowBranchesOnScriptFailureAndPersistsEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        XCTAssertEqual(model.selected?.nodes.count, 5, model.error)
        let script = try XCTUnwrap(model.file.workflows[0].nodes.firstIndex { $0.kind == .script })
        model.file.workflows[0].nodes[script].command = "echo branch-test; exit 3"
        model.save()
        XCTAssertTrue(model.error.isEmpty)
        let reloaded = WorkflowController()
        reloaded.configure(workspace, root: root)
        let reloadedFlow = try XCTUnwrap(reloaded.file.workflows.first, reloaded.error)
        XCTAssertEqual(reloadedFlow.nodes[script].command, "echo branch-test; exit 3")
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        reloaded.run(workspace: workspace, root: root, runner: runner, trusted: true)
        let deadline = Date().addingTimeInterval(5)
        while reloaded.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(reloaded.isRunning)
        XCTAssertTrue(reloaded.log.contains("No"))
        XCTAssertTrue(reloaded.log.contains("Fin: Revisar cambios"))
        XCTAssertFalse(reloaded.log.contains("Fin: Proyecto listo"))
    }

    func testScriptSettingsPersistAndApplyToProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subfolder = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        let index = try XCTUnwrap(model.file.workflows[0].nodes.firstIndex { $0.kind == .script })
        model.file.workflows[0].nodes[index].command = "printf '%s:%s' \"$BRAKET_TEST\" \"$PWD\""
        model.file.workflows[0].nodes[index].settings = WorkflowScriptSettings(
            workingDirectory: "scripts", timeoutSeconds: 5,
            environment: [WorkflowEnvironmentVariable(name: "BRAKET_TEST", value: "configured")])
        model.save()
        XCTAssertTrue(model.error.isEmpty, model.error)

        let restored = WorkflowController()
        restored.configure(workspace, root: root)
        XCTAssertEqual(restored.selected?.nodes[index].settings.timeoutSeconds, 5)
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        restored.run(workspace: workspace, root: root, runner: runner, trusted: true)
        let deadline = Date().addingTimeInterval(8)
        while restored.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(restored.isRunning)
        XCTAssertTrue(restored.log.contains("configured:\(subfolder.path)"), restored.log)
    }

    func testScriptTimeoutMarksStepAsFailed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.kzk")
        let model = WorkflowController()
        model.configure(workspace, root: root)
        let index = try XCTUnwrap(model.file.workflows[0].nodes.firstIndex { $0.kind == .script })
        model.file.workflows[0].nodes[index].command = "sleep 5"
        model.file.workflows[0].nodes[index].settings.timeoutSeconds = 1
        let id = model.file.workflows[0].nodes[index].id
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        model.run(workspace: workspace, root: root, runner: runner, trusted: true)
        let deadline = Date().addingTimeInterval(8)
        while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.visited[id], .failed("Tiempo límite de 1 s agotado"))
        XCTAssertTrue(model.log.contains("Fin: Revisar cambios"), model.log)
    }
}
