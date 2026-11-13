@testable import Krabzik
import XCTest

@MainActor
final class SessionRestorationTests: XCTestCase {
    private func environment() throws -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "krabzik-session-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (directory, defaults)
    }

    private func project(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(name).kzk")
        try Workspace(name: name).write(to: url)
        return url
    }

    private func file(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("SELECT 1;".utf8).write(to: url)
        return url
    }

    private func snapshot(_ url: URL, files: [URL] = [], selected: URL? = nil) -> SavedWorkspaceState {
        SavedWorkspaceState(workspaceURL: url, openFiles: files, selectedFile: selected,
                            selectedProjectID: nil, sidebarVisible: true, processesVisible: true)
    }

    func testSettingsPersistAndDefaultToGraphiteWithRestorationDisabled() throws {
        let (_, defaults) = try environment()
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.theme, .graphite)
        XCTAssertFalse(settings.restoreLastState)
        XCTAssertEqual(settings.markdownPreviewZoom, 1)
        settings.theme = .midnight
        settings.restoreLastState = true
        settings.markdownPreviewZoom = 1.4
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.theme, .midnight)
        XCTAssertTrue(reloaded.restoreLastState)
        XCTAssertEqual(reloaded.markdownPreviewZoom, 1.4)
    }

    func testRestoresProjectTabOrderAndSelectionWithoutRunningApprovedCommands() async throws {
        let (directory, defaults) = try environment()
        let url = directory.appendingPathComponent("Estado.kzk")
        let marker = directory.appendingPathComponent("must-not-run")
        var workspace = Workspace(name: "Estado")
        let active = CodeProject(name: "API", path: ".", kind: .files, command: "touch '\(marker.path)'")
        workspace.projects = [active]
        try workspace.write(to: url)
        let firstFile = try file("primero.sql", in: directory)
        let secondFile = try file("segundo.sql", in: directory)
        let first = WorkspaceController(defaults: defaults)
        first.trust.markTrusted(url)
        first.trust.approve(command: active.command, project: active.id, workspaceURL: url)
        first.settings.restoreLastState = true
        await first.openWorkspace(url)
        try await first.docs.open(firstFile)
        try await first.docs.open(secondFile)
        first.selectedDocumentID = firstFile
        first.selectedProjectID = active.id
        first.sidebarVisible = false
        first.processesVisible = false
        first.runner.state(for: active.id).status = .running
        first.saveSessionState(first.captureSessionState())

        let restored = WorkspaceController(defaults: defaults)
        await restored.start(arguments: ["Krabzik"])

        XCTAssertEqual(restored.workspaceURL, url.standardizedFileURL)
        XCTAssertEqual(restored.documents.map(\.url), [firstFile, secondFile].map(\.standardizedFileURL))
        XCTAssertEqual(restored.selectedDocumentID, firstFile.standardizedFileURL)
        XCTAssertEqual(restored.selectedProjectID, active.id)
        XCTAssertFalse(restored.sidebarVisible)
        XCTAssertFalse(restored.processesVisible)
        XCTAssertFalse(restored.runner.hasActiveProcesses)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(restored.isRestoringSession)
        await restored.start(arguments: ["Krabzik"])
        XCTAssertEqual(restored.documents.count, 2)
    }

    func testDisabledRestorationAndDisablingTheSettingClearTheSavedState() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Anterior", in: directory)
        let controller = WorkspaceController(defaults: defaults)
        controller.restoration.save(snapshot(url))
        await controller.start(arguments: ["Krabzik"])
        XCTAssertNil(controller.workspaceURL)
        controller.settings.restoreLastState = true
        controller.settings.restoreLastState = false
        XCTAssertNil(controller.restoration.load())
    }

    func testAnExplicitLaunchProjectOverridesTheSavedSession() async throws {
        let (directory, defaults) = try environment()
        let saved = try project("Guardado", in: directory)
        let explicit = try project("Solicitado", in: directory)
        let controller = WorkspaceController(defaults: defaults)
        controller.settings.restoreLastState = true
        controller.trust.markTrusted(explicit)
        controller.restoration.save(snapshot(saved, files: [try file("anterior.sql", in: directory)]))

        await controller.start(arguments: ["Krabzik", "--workspace", explicit.path])

        XCTAssertEqual(controller.workspaceURL, explicit.standardizedFileURL)
        XCTAssertTrue(controller.documents.isEmpty)
    }

    func testFinderRequestDuringRestorationWinsWithoutRestoringOldTabs() async throws {
        let (directory, defaults) = try environment()
        let saved = try project("Guardado", in: directory)
        let explicit = try project("Finder", in: directory)
        let controller = WorkspaceController(defaults: defaults)
        controller.settings.restoreLastState = true
        controller.trust.markTrusted(explicit)
        controller.restoration.save(snapshot(saved, files: [try file("anterior.sql", in: directory)]))
        controller.confirmTrust = { [weak controller] _ in
            controller?.requestWorkspace(explicit)
            return .readOnly
        }

        await controller.start(arguments: ["Krabzik"])

        XCTAssertEqual(controller.workspaceURL, explicit.standardizedFileURL)
        XCTAssertTrue(controller.documents.isEmpty)
        XCTAssertFalse(controller.isRestoringSession)
    }

    func testClosingTheProjectClearsTheSessionSoNextLaunchShowsHome() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Cerrado", in: directory)
        let controller = WorkspaceController(defaults: defaults)
        controller.trust.markTrusted(url)
        controller.settings.restoreLastState = true
        await controller.openWorkspace(url)
        controller.saveSessionState(controller.captureSessionState())
        await controller.closeWorkspace()

        XCTAssertNil(controller.restoration.load())
        let next = WorkspaceController(defaults: defaults)
        await next.start(arguments: ["Krabzik"])
        XCTAssertNil(next.workspaceURL)
    }

    func testUnavailableFilesDoNotPreventRestoringRemainingTabs() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Parcial", in: directory)
        let available = try file("disponible.sql", in: directory)
        let missing = directory.appendingPathComponent("borrado.sql")
        let controller = WorkspaceController(defaults: defaults)
        controller.settings.restoreLastState = true
        controller.trust.markTrusted(url)
        controller.restoration.save(snapshot(url, files: [missing, available, available], selected: missing))

        await controller.start(arguments: ["Krabzik"])

        XCTAssertEqual(controller.documents.map(\.url), [available.standardizedFileURL])
        XCTAssertEqual(controller.selectedDocumentID, available.standardizedFileURL)
        XCTAssertNotNil(controller.errors.current)
        XCTAssertFalse(controller.isRestoringSession)
    }

    func testReadOnlyRestorationDoesNotOpenExternalFiles() async throws {
        let (directory, defaults) = try environment()
        let root = directory.appendingPathComponent("Proyecto")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try project("Lectura", in: root)
        let internalFile = try file("interno.sql", in: root)
        let externalFile = try file("externo.sql", in: directory)
        let controller = WorkspaceController(defaults: defaults)
        controller.settings.restoreLastState = true
        controller.confirmTrust = { _ in .readOnly }
        controller.restoration.save(snapshot(url, files: [internalFile, externalFile], selected: externalFile))

        await controller.start(arguments: ["Krabzik"])

        XCTAssertTrue(controller.isReadOnly)
        XCTAssertEqual(controller.documents.map(\.url), [internalFile.standardizedFileURL])
        XCTAssertFalse(controller.runner.hasActiveProcesses)
    }

    func testMalformedAndUnknownSessionFormatsAreIgnored() throws {
        let (_, defaults) = try environment()
        let store = SessionRestoration(defaults: defaults)
        defaults.set(Data("not JSON".utf8), forKey: SessionRestoration.key)
        XCTAssertNil(store.load())
        var future = snapshot(URL(fileURLWithPath: "/tmp/future.kzk"))
        future.version = 2
        store.save(future)
        XCTAssertNil(store.load())
    }
}
