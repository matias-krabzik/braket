@testable import Krabzik
import XCTest

@MainActor
final class WorkspaceSidebarTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testFilterFindsNestedFilesAndSkipsGeneratedFoldersAndSymlinks() throws {
        let root = try directory()
        for folder in ["src", "node_modules", ".git"] {
            let target = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data().write(to: target.appendingPathComponent("index.php"))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"),
                                                   withDestinationURL: root.appendingPathComponent("src"))
        let result = try SidebarFileSearch.find("INDEX", roots: [("api", root)])
        XCTAssertEqual(result.matches.map(\.path), ["api/src/index.php"])
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(try SidebarFileSearch.find("src/index", roots: [("api", root)]).matches.count, 1)
        XCTAssertTrue(try SidebarFileSearch.find("missing", roots: [("api", root)]).matches.isEmpty)
    }

    func testFilterLimitsResultsAndDeduplicatesRoots() throws {
        let root = try directory()
        for i in 0..<3 { try Data().write(to: root.appendingPathComponent("file\(i).txt")) }
        let limited = try SidebarFileSearch.find("file", roots: [("api", root)], limit: 2)
        XCTAssertEqual(limited.matches.count, 2)
        XCTAssertTrue(limited.truncated)
        XCTAssertEqual(try SidebarFileSearch.find("file", roots: [("api", root), ("copy", root)]).matches.count, 3)
    }

    func testLegacyDatabaseTabSessionRestoresInUnifiedExplorer() async throws {
        let root = try directory()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let controller = WorkspaceController(defaults: defaults)
        let project = root.appendingPathComponent("A.kzk")
        let script = root.appendingPathComponent("query.sql")
        try Workspace(name: "A").write(to: project)
        try Data("SELECT 1".utf8).write(to: script)
        controller.trust.markTrusted(project)
        await controller.openWorkspace(project)
        try await controller.docs.open(script)
        let saved = try XCTUnwrap(controller.captureSessionState())
        let data = try JSONEncoder().encode(saved)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["sidebarTab"] = "database"
        let legacy = try JSONDecoder().decode(SavedWorkspaceState.self, from: JSONSerialization.data(withJSONObject: old))
        let restored = WorkspaceController(defaults: defaults)
        await restored.restoreSession(legacy)
        XCTAssertEqual(restored.workspaceURL, project)
        XCTAssertEqual(restored.selectedDocument?.url, script)
    }

    func testStandaloneScriptIsAnExplorerRootWithoutLoadingItAsDirectory() throws {
        let root = try directory()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let controller = WorkspaceController(defaults: defaults)
        let url = root.appendingPathComponent("A.kzk")
        var workspace = Workspace(name: "A")
        workspace.scripts = ["query.sql"]
        controller.session.open(workspace, at: url, trust: .trusted)
        let coordinator = FileTree.Coordinator(controller: controller)
        coordinator.update(workspace, at: url, revision: 1)
        XCTAssertEqual(coordinator.roots.map(\.url), [root.appendingPathComponent("query.sql")])
        XCTAssertFalse(try XCTUnwrap(coordinator.roots.first).isDirectory)
        XCTAssertFalse(try XCTUnwrap(coordinator.roots.first).loading)
    }

    func testAgentUsesEditorTabsAndRestoresItsSessionWithoutLosingTheActiveFile() async throws {
        let root = try directory()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let controller = WorkspaceController(defaults: defaults)
        let url = root.appendingPathComponent("test.kzk")
        try Workspace(name: "Test").write(to: url)
        controller.trust.markTrusted(url)
        await controller.openWorkspace(url)
        let file = root.appendingPathComponent("test.swift")
        try "let test = 1".write(to: file, atomically: true, encoding: .utf8)
        try await controller.docs.open(file)
        controller.openAgent(newSession: true)
        controller.agent.draft = "Revisar selección"
        XCTAssertEqual(controller.selectedDocumentID, file)
        XCTAssertTrue(controller.agent.visible)
        XCTAssertTrue(controller.agent.tabOpen)
        XCTAssertTrue(controller.sessionsSidebarVisible)
        controller.workflowVisible = true
        XCTAssertFalse(controller.agent.visible)
        controller.openAgent()
        XCTAssertFalse(controller.workflowVisible)
        controller.selectedDocumentID = file
        XCTAssertFalse(controller.agent.visible)
        XCTAssertTrue(controller.agent.tabOpen)
        controller.openAgent()
        let state = try XCTUnwrap(controller.captureSessionState())
        controller.agent.shutdown()
        let restored = WorkspaceController(defaults: defaults)
        await restored.restoreSession(state)
        XCTAssertTrue(restored.agent.visible)
        XCTAssertTrue(restored.agent.tabOpen)
        XCTAssertEqual(restored.agent.selectedSessionID, controller.agent.selectedSessionID)
        XCTAssertEqual(restored.agent.draft, "Revisar selección")
        XCTAssertEqual(restored.selectedDocumentID, file)
    }
}
