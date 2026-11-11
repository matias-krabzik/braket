@testable import Krabzik
import XCTest

@MainActor
final class OpenWorkspacesTests: XCTestCase {
    private func setup() throws -> (WorkspaceController, URL, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let a = root.appendingPathComponent("A.kzk"), b = root.appendingPathComponent("B.kzk")
        try Workspace(name: "A").write(to: a)
        try Workspace(name: "B").write(to: b)
        let controller = WorkspaceController(defaults: defaults)
        controller.trust.markTrusted(a)
        controller.trust.markTrusted(b)
        return (controller, a, b, defaults)
    }

    func testOpenProjectsAreNotRecentsAndSwitchingPreservesOrderAndTabs() async throws {
        let (controller, a, b, _) = try setup()
        controller.recents.remember(b)
        await controller.openWorkspace(a)
        XCTAssertEqual(controller.openWorkspaceURLs, [a])
        let file = a.deletingLastPathComponent().appendingPathComponent("file.txt")
        try Data("hello".utf8).write(to: file)
        try await controller.docs.open(file)
        await controller.openWorkspace(b)
        XCTAssertTrue(controller.documents.isEmpty)
        await controller.openWorkspace(a)
        XCTAssertEqual(controller.openWorkspaceURLs, [a, b])
        XCTAssertEqual(controller.documents.map(\.url), [file])
        controller.moveOpenWorkspace(b, to: a)
        XCTAssertEqual(controller.openWorkspaceURLs, [b, a])
        await controller.openWorkspace(b)
        XCTAssertEqual(controller.openWorkspaceURLs, [b, a])
    }

    func testClosingInactiveAndLastProjectKeepsHistoryAndFiles() async throws {
        let (controller, a, b, _) = try setup()
        await controller.openWorkspace(a)
        await controller.openWorkspace(b)
        await controller.closeWorkspace(a)
        XCTAssertEqual(controller.workspaceURL, b)
        XCTAssertEqual(controller.openWorkspaceURLs, [b])
        await controller.closeWorkspace()
        XCTAssertNil(controller.workspaceURL)
        XCTAssertTrue(controller.openWorkspaceURLs.isEmpty)
        XCTAssertTrue(controller.recentProjects.contains(a))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testClosingSelectedProjectSelectsAnotherOpenProject() async throws {
        let (controller, a, b, _) = try setup()
        await controller.openWorkspace(a)
        await controller.openWorkspace(b)
        await controller.closeWorkspace(b)
        XCTAssertEqual(controller.workspaceURL, a)
        XCTAssertEqual(controller.openWorkspaceURLs, [a])
    }

    func testRestorationKeepsOpenProjectsTheirOrderAndSelection() async throws {
        let (controller, a, b, defaults) = try setup()
        controller.settings.restoreLastState = true
        await controller.openWorkspace(a)
        await controller.openWorkspace(b)
        controller.moveOpenWorkspace(b, to: a)
        controller.saveSessionState(controller.captureSessionState())
        let restored = WorkspaceController(defaults: defaults)
        await restored.start(arguments: [])
        XCTAssertEqual(restored.openWorkspaceURLs, [b, a])
        XCTAssertEqual(restored.workspaceURL, b)
        XCTAssertFalse(restored.runner.hasActiveProcesses)
    }

    func testCancelledCloseKeepsBothProjectsAndDirtyText() async throws {
        let (controller, a, b, _) = try setup()
        await controller.openWorkspace(a)
        await controller.openWorkspace(b)
        let file = b.deletingLastPathComponent().appendingPathComponent("dirty.txt")
        try Data("original".utf8).write(to: file)
        try await controller.docs.open(file)
        let document = try XCTUnwrap(controller.selectedDocument)
        document.text = "unsaved"
        document.isDirty = true
        controller.session.dialogs.confirmSave = { _ in .cancel }
        await controller.closeWorkspace(b)
        XCTAssertEqual(controller.openWorkspaceURLs, [a, b])
        XCTAssertEqual(controller.workspaceURL, b)
        XCTAssertEqual(controller.selectedDocument?.text, "unsaved")
    }

    func testIdentityPersistsAndRelocationPreservesCodeAndTabs() async throws {
        let (controller, a, _, _) = try setup()
        let root = a.deletingLastPathComponent()
        let code = root.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
        let file = code.appendingPathComponent("test.sql")
        try Data("select 1;".utf8).write(to: file)
        var workspace = Workspace(name: "A", projects: [CodeProject(name: "Code", path: "code", kind: .files, command: "")])
        workspace.scripts = ["code/test.sql"]
        try workspace.write(to: a)
        await controller.openWorkspace(a)
        try await controller.docs.open(file)
        XCTAssertTrue(controller.saveProjectIdentity(name: "Renamed", icon: ProjectIconStyle(hex: "4589E8", glass: true)))
        let saved = try Workspace.read(from: a)
        XCTAssertEqual(saved.name, "Renamed")
        XCTAssertEqual(saved.iconStyle.hex, "4589E8")
        let folder = ProjectStorage.folder(name: "Renamed", year: 2026, root: root.appendingPathComponent("BraketProjects"))
        let destination = folder.appendingPathComponent("A.kzk")
        let moved = await controller.relocateWorkspace(to: destination, createDirectory: true)
        XCTAssertTrue(moved)
        XCTAssertEqual(controller.workspaceURL, destination)
        XCTAssertEqual(controller.openWorkspaceURLs, [destination])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertEqual(try Data(contentsOf: file), Data("select 1;".utf8))
        XCTAssertEqual(controller.documents.map(\.url), [file])
        let relocated = try Workspace.read(from: destination)
        XCTAssertEqual(relocated.projects.first?.directory(relativeTo: destination).path, code.path)
        XCTAssertEqual(relocated.scripts, [file.path])
        XCTAssertEqual(relocated.iconStyle, saved.iconStyle)
    }

    func testRelocationRefusesToOverwriteAndReadOnlyCannotEdit() async throws {
        let (controller, a, b, _) = try setup()
        let original = try Data(contentsOf: b)
        await controller.openWorkspace(a)
        let moved = await controller.relocateWorkspace(to: b)
        XCTAssertFalse(moved)
        XCTAssertEqual(try Data(contentsOf: b), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(controller.saveProjectIdentity(name: "A", icon: ProjectIconStyle(hex: "invalid")))
        await controller.closeWorkspace()
        controller.trust.forget(a)
        controller.confirmTrust = { _ in .readOnly }
        await controller.openWorkspace(a)
        XCTAssertFalse(controller.saveProjectIdentity(name: "Blocked", icon: ProjectIconStyle()))
        XCTAssertEqual(try Workspace.read(from: a).name, "A")
    }
}
