@testable import Krabzik
import XCTest

/// Los scripts de una automatización no corren solo porque el proyecto sea confiable.
/// Ver `WorkflowScriptApproval`: la aprobación es por hash de comando, carpeta y entorno.
@MainActor final class WorkflowApprovalTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private let runner = ProcessRunner()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = root.appendingPathComponent("Example.kzk")
    }

    override func tearDown() async throws {
        runner.terminateImmediately()
        try? FileManager.default.removeItem(at: root)
    }

    private func store() throws -> TrustStore {
        try TrustStore(defaults: XCTUnwrap(UserDefaults(suiteName: "WorkflowApprovalTests-\(UUID().uuidString)")))
    }

    private func controller(command: String = "touch ran.marker") throws -> (WorkflowController, Int) {
        let model = WorkflowController()
        model.configure(workspace, root: root)
        let script = try XCTUnwrap(model.file.workflows[0].nodes.firstIndex { $0.kind == .script })
        model.file.workflows[0].nodes[script].command = command
        return (model, script)
    }

    private func run(_ model: WorkflowController, store: TrustStore) async throws {
        model.run(workspace: workspace, root: root, runner: runner, trusted: true, approvals: store)
        let deadline = Date().addingTimeInterval(8)
        while model.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(model.isRunning)
    }

    private var marker: URL { root.appendingPathComponent("ran.marker") }

    func testUnapprovedScriptDoesNotRunByDefault() async throws {
        let (model, _) = try controller()
        try await run(model, store: try store())
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(model.error.contains("aprobar"), model.error)
        XCTAssertTrue(model.log.isEmpty, "no arrancó ningún bloque")
    }

    func testDecliningStopsBeforeAnyBlockRuns() async throws {
        let (model, _) = try controller()
        var asked: [CommandPrompt] = []
        model.confirmCommand = { prompt in asked.append(prompt)
            return .cancel }
        try await run(model, store: try store())
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.command, "touch ran.marker")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testRunOnceAsksAgainAndAlwaysRemembers() async throws {
        let (model, _) = try controller()
        let approvals = try store()
        var asks = 0
        model.confirmCommand = { _ in asks += 1
            return .once }
        try await run(model, store: approvals)
        try await run(model, store: approvals)
        XCTAssertEqual(asks, 2, "«una vez» no se recuerda")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        model.confirmCommand = { _ in asks += 1
            return .always }
        try await run(model, store: approvals)
        let afterAlways = asks
        try await run(model, store: approvals)
        XCTAssertEqual(asks, afterAlways, "ya aprobado: no vuelve a preguntar")
    }

    /// Lo aprobado es el conjunto completo: cambiar el comando, la carpeta o una variable
    /// vuelve a preguntar. Si solo se hasheara el comando, un flujo editado después de
    /// aprobarlo podría cambiar de carpeta o de entorno sin que nadie lo vea.
    func testChangingCommandDirectoryOrEnvironmentRevokesApproval() async throws {
        let (model, script) = try controller()
        let approvals = try store()
        var asks = 0
        model.confirmCommand = { _ in asks += 1
            return .always }
        try await run(model, store: approvals)
        XCTAssertEqual(asks, 1)
        try await run(model, store: approvals)
        XCTAssertEqual(asks, 1)

        model.file.workflows[0].nodes[script].settings.environment = [WorkflowEnvironmentVariable(name: "A", value: "1")]
        try await run(model, store: approvals)
        XCTAssertEqual(asks, 2, "una variable nueva")

        model.file.workflows[0].nodes[script].settings.environment[0].value = "2"
        try await run(model, store: approvals)
        XCTAssertEqual(asks, 3, "otro valor")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        model.file.workflows[0].nodes[script].settings.workingDirectory = "sub"
        try await run(model, store: approvals)
        XCTAssertEqual(asks, 4, "otra carpeta")

        model.file.workflows[0].nodes[script].command = "touch other.marker"
        try await run(model, store: approvals)
        XCTAssertEqual(asks, 5, "otro comando")
    }

    func testApprovalDoesNotTransferToAnotherProject() throws {
        let (model, script) = try controller()
        let node = model.file.workflows[0].nodes[script]
        let approvals = try store()
        let approval = WorkflowScriptApproval(node: node, root: root)
        approvals.approve(command: approval.key, project: node.id, workspaceURL: workspace)
        XCTAssertTrue(approval.authorize(store: approvals, workspaceURL: workspace) { _ in .cancel })
        let other = root.appendingPathComponent("Other.kzk")
        XCTAssertFalse(approval.authorize(store: approvals, workspaceURL: other) { _ in .cancel })
    }

    func testPromptShowsExternalDirectoryAndEnvironment() throws {
        let (model, script) = try controller()
        var node = model.file.workflows[0].nodes[script]
        node.settings.workingDirectory = "/usr"
        node.settings.environment = [WorkflowEnvironmentVariable(name: "TOKEN", value: "abc"),
                                     WorkflowEnvironmentVariable(name: "A", value: "1")]
        let prompt = WorkflowScriptApproval(node: node, root: root).prompt
        XCTAssertTrue(prompt.isExternal)
        XCTAssertEqual(prompt.directory, "/usr")
        XCTAssertEqual(prompt.environment, ["A=1", "TOKEN=abc"])

        node.settings.workingDirectory = ".."
        XCTAssertTrue(WorkflowScriptApproval(node: node, root: root).isExternal, "«..» sale del proyecto")
        node.settings.workingDirectory = "sub"
        XCTAssertFalse(WorkflowScriptApproval(node: node, root: root).isExternal)
    }

    func testRelativeDirectoryThroughSymlinkIsShownAtItsRealPlace() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let (model, script) = try controller()
        var node = model.file.workflows[0].nodes[script]
        node.settings.workingDirectory = "link"
        XCTAssertTrue(WorkflowScriptApproval(node: node, root: root).isExternal)
    }

    func testReservedEnvironmentNamesAreRejected() throws {
        for name in ["DYLD_INSERT_LIBRARIES", "dyld_library_path", "LD_PRELOAD", "ZDOTDIR", "BASH_ENV", "ENV", "SHELL", "IFS"] {
            var flow = Workflow.first()
            let script = try XCTUnwrap(flow.nodes.firstIndex { $0.kind == .script })
            flow.nodes[script].settings.environment = [WorkflowEnvironmentVariable(name: name, value: "x")]
            XCTAssertThrowsError(try WorkflowFile(workflows: [flow]).validate(), name)
        }
        var flow = Workflow.first()
        let script = try XCTUnwrap(flow.nodes.firstIndex { $0.kind == .script })
        flow.nodes[script].settings.environment = [WorkflowEnvironmentVariable(name: "NODE_OPTIONS", value: "--max-old-space-size=4096"),
                                                   WorkflowEnvironmentVariable(name: "PATH", value: "/usr/bin")]
        XCTAssertNoThrow(try WorkflowFile(workflows: [flow]).validate())
    }

    func testOnlyScriptsReachableFromTheTriggerNeedApproval() throws {
        var flow = Workflow.first()
        let orphan = WorkflowNode(kind: .script, title: "Huérfano", command: "echo x", x: 0, y: 0)
        flow.nodes.append(orphan)
        let scripts = flow.scripts(from: .start)
        XCTAssertEqual(scripts.count, 1)
        XCTAssertFalse(scripts.contains { $0.id == orphan.id })
    }

    func testSymlinkedAutomationsFolderIsNeverReadOrWritten() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let braket = root.appendingPathComponent(".braket")
        try FileManager.default.createDirectory(at: braket, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: braket.appendingPathComponent("automations"),
                                                   withDestinationURL: outside)

        let model = WorkflowController()
        model.configure(workspace, root: root)
        XCTAssertTrue(model.error.contains("enlace simbólico"), model.error)
        XCTAssertTrue(model.file.workflows.isEmpty)

        let writer = WorkflowController()
        writer.file = WorkflowFile(workflows: [.first()])
        writer.configure(workspace, root: root)
        writer.file = WorkflowFile(workflows: [.first()])
        writer.save()
        XCTAssertTrue(writer.error.contains("enlace simbólico"), writer.error)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testSymlinkedFlowFileIsRejected() throws {
        let model = WorkflowController()
        model.configure(workspace, root: root)
        model.save()
        let path = try XCTUnwrap(model.selected.flatMap { model.storageURL(for: $0) })
        let target = root.appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: path, to: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)

        let reloaded = WorkflowController()
        reloaded.configure(workspace, root: root)
        XCTAssertTrue(reloaded.error.contains("enlace simbólico"), reloaded.error)
    }
}
