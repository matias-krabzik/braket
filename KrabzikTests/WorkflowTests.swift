@testable import Krabzik
import XCTest

@MainActor final class WorkflowTests: XCTestCase {
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
}
