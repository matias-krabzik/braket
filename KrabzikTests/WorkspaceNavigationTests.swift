@testable import Krabzik
import XCTest

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    private func environment() throws -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "krabzik-navigation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (directory, defaults)
    }

    private func project(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(name).krabzik")
        try Workspace(name: name).write(to: url)
        return url
    }

    func testNormalLaunchShowsHomeEvenWithRecentProject() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Reciente", in: directory)
        defaults.set([url.path], forKey: "recentProjects")
        let controller = WorkspaceController(defaults: defaults)

        await controller.start(arguments: ["Krabzik"])

        XCTAssertNil(controller.workspace)
        XCTAssertNil(controller.workspaceURL)
        XCTAssertEqual(controller.recentProjects, [url])
        XCTAssertTrue(controller.documents.isEmpty)
        XCTAssertFalse(controller.runner.hasActiveProcesses)
    }

    func testExplicitLaunchOpensRequestedProjectOnlyOnce() async throws {
        let (directory, defaults) = try environment()
        let first = try project("Primero", in: directory)
        let second = try project("Segundo", in: directory)
        defaults.set([first.path], forKey: "recentProjects")
        let controller = WorkspaceController(defaults: defaults)

        await controller.start(arguments: ["Krabzik", "--workspace", second.path])
        XCTAssertEqual(controller.workspace?.name, "Segundo")
        XCTAssertEqual(controller.recentProjects, [second, first])
        await controller.start(arguments: ["Krabzik", "--workspace", first.path])
        XCTAssertEqual(controller.workspaceURL, second)
    }

    func testRecentProjectsPersistInOpeningOrderWithoutDuplicatesAndStayBounded() async throws {
        let (directory, defaults) = try environment()
        let urls = try (0..<12).map { try project("Proyecto \($0)", in: directory) }
        let controller = WorkspaceController(defaults: defaults)
        for url in urls { await controller.openWorkspace(url) }
        XCTAssertEqual(controller.recentProjects, Array(urls.reversed().prefix(10)))

        await controller.openWorkspace(urls[5])
        let expected = [urls[5]] + urls.reversed().filter { $0 != urls[5] && $0 != urls[0] && $0 != urls[1] }
        XCTAssertEqual(controller.recentProjects, expected)
        XCTAssertEqual(WorkspaceController(defaults: defaults).recentProjects, expected)
    }

    func testRemovingRecentDoesNotDeleteOrCloseProject() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Conservar", in: directory)
        let controller = WorkspaceController(defaults: defaults)
        await controller.openWorkspace(url)

        controller.removeRecentProject(url)

        XCTAssertTrue(controller.recentProjects.isEmpty)
        XCTAssertTrue(WorkspaceController(defaults: defaults).recentProjects.isEmpty)
        XCTAssertEqual(controller.workspaceURL, url)
        XCTAssertEqual(try Workspace.read(from: url).name, "Conservar")
    }

    func testReturningHomeClearsEditorAndDatabaseSelectionButKeepsHistory() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Proyecto", in: directory)
        let controller = WorkspaceController(defaults: defaults)
        await controller.openWorkspace(url)
        let document = try EditorDocument(url: directory.appendingPathComponent("test.sql"), data: Data("SELECT 1;".utf8))
        controller.documents = [document]
        controller.selectedDocumentID = document.id
        controller.selectedProjectID = UUID()
        controller.database.install([DatabaseConnection()])

        await controller.closeWorkspace()

        XCTAssertNil(controller.workspace)
        XCTAssertNil(controller.workspaceURL)
        XCTAssertTrue(controller.documents.isEmpty)
        XCTAssertNil(controller.selectedDocumentID)
        XCTAssertNil(controller.selectedProjectID)
        XCTAssertNil(controller.database.selectedConnectionID)
        XCTAssertTrue(controller.database.states.isEmpty)
        XCTAssertFalse(controller.isSwitchingWorkspace)
        XCTAssertEqual(controller.recentProjects, [url])
        await controller.openWorkspace(url)
        XCTAssertEqual(controller.workspaceURL, url)
    }

    func testMissingRecentReportsErrorAndPreservesCurrentProject() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Disponible", in: directory)
        let missing = directory.appendingPathComponent("Movido.krabzik")
        defaults.set([missing.path], forKey: "recentProjects")
        let controller = WorkspaceController(defaults: defaults)

        await controller.openWorkspace(missing)
        XCTAssertNil(controller.workspace)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.recentProjects, [missing])
        XCTAssertFalse(controller.isSwitchingWorkspace)

        await controller.openWorkspace(url)
        controller.errorMessage = nil
        await controller.openWorkspace(missing)
        XCTAssertEqual(controller.workspaceURL, url)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(controller.recentProjects, [url, missing])
    }
}
