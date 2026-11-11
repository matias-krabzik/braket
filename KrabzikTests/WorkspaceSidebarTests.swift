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

    func testTabSelectionFollowsProjectAndRestoredSession() async throws {
        let root = try directory()
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let controller = WorkspaceController(defaults: defaults)
        let a = root.appendingPathComponent("A.kzk"), b = root.appendingPathComponent("B.kzk")
        try Workspace(name: "A").write(to: a)
        try Workspace(name: "B").write(to: b)
        controller.trust.markTrusted(a)
        controller.trust.markTrusted(b)
        await controller.openWorkspace(a)
        controller.sidebarTab = .database
        await controller.openWorkspace(b)
        XCTAssertEqual(controller.sidebarTab, .code)
        await controller.openWorkspace(a)
        XCTAssertEqual(controller.sidebarTab, .database)
        let saved = try XCTUnwrap(controller.captureSessionState())
        let restored = WorkspaceController(defaults: defaults)
        await restored.restoreSession(saved)
        XCTAssertEqual(restored.sidebarTab, .database)
        var old = saved
        old.sidebarTab = nil
        await restored.restoreTabs(old)
        XCTAssertEqual(restored.sidebarTab, .code)
    }
}
