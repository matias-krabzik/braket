@testable import Krabzik
import XCTest

@MainActor
final class ProjectClosingTests: XCTestCase {
    private func environment(command: String = "") async throws -> (WorkspaceController, URL, CodeProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let url = root.appendingPathComponent("Close.kzk")
        let project = CodeProject(name: "Worker", path: ".", kind: .files, command: command)
        try Workspace(name: "Close", projects: [project]).write(to: url)
        let controller = WorkspaceController(defaults: defaults)
        controller.trust.markTrusted(url)
        await controller.openWorkspace(url)
        addTeardownBlock { @MainActor in
            controller.runner.terminateImmediately()
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        return (controller, url, project)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    func testQuitAsksBeforeSavingEdits() async throws {
        let (controller, url, _) = try await environment()
        let file = url.deletingLastPathComponent().appendingPathComponent("query.sql")
        try Data("SELECT 1;".utf8).write(to: file)
        try await controller.docs.open(file)
        let document = try XCTUnwrap(controller.selectedDocument)
        document.text = "SELECT 2;"
        document.isDirty = true
        var savePrompts = 0
        controller.session.dialogs.confirmSave = { name in
            XCTAssertEqual(name, "query.sql")
            savePrompts += 1
            return .save
        }
        controller.session.dialogs.confirmStopProcesses = { XCTFail("No hay una ejecución activa")
        return false }

        let allowed = await controller.prepareToQuit()
        XCTAssertTrue(allowed)
        XCTAssertEqual(savePrompts, 1)
        XCTAssertEqual(controller.workspaceURL, url)
        XCTAssertEqual(controller.documents.map(\.url), [file.standardizedFileURL])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "SELECT 2;")
    }

    func testQuitCanDiscardDraftWithoutChoosingLocation() async throws {
        let (controller, url, _) = try await environment()
        let draft = try controller.docs.createDraft(name: "customers.sql", text: "SELECT 1;")
        var prompts = 0
        controller.session.dialogs.confirmSave = { name in
            XCTAssertEqual(name, "customers.sql")
            prompts += 1
            return .discard
        }
        controller.session.dialogs.chooseScriptsDirectory = { _ in
            XCTFail("Descartar no debe pedir carpeta de scripts")
            return nil
        }
        controller.session.dialogs.saveCopy = { _, _ in
            XCTFail("Descartar no debe abrir Guardar como")
            return nil
        }
        let allowed = await controller.prepareToQuit()
        XCTAssertTrue(allowed)
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(draft.isDraft)
        XCTAssertEqual(controller.workspaceURL, url)
    }

    func testQuitCancellationKeepsDirtyDraftOpen() async throws {
        let (controller, _, _) = try await environment()
        let draft = try controller.docs.createDraft(name: "customers.sql", text: "SELECT 1;")
        controller.session.dialogs.confirmSave = { _ in .cancel }
        let allowed = await controller.prepareToQuit()
        XCTAssertFalse(allowed)
        XCTAssertTrue(controller.documents.contains { $0 === draft })
    }

    func testQuitWarnsAndCanBeCancelledWhenProcessRuns() async throws {
        let (controller, url, project) = try await environment(command: "/bin/sleep 30")
        controller.runner.start(project, workspaceURL: url)
        let running = await waitUntil { controller.runner.hasActiveProcesses }
        XCTAssertTrue(running)
        var prompts = 0
        controller.session.dialogs.confirmStopProcesses = { prompts += 1
        return false }

        let allowed = await controller.prepareToQuit()
        XCTAssertFalse(allowed)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(controller.workspaceURL, url)
        XCTAssertTrue(controller.runner.hasActiveProcesses)
    }

    func testNoProcessClosesOnlyAfterConfirmation() async throws {
        let (controller, url, _) = try await environment()
        let closing = ProjectClosing(controller: controller, url: url)
        XCTAssertEqual(controller.workspaceURL, url)
        XCTAssertEqual(closing.phase, .confirmation)
        await closing.confirm()
        XCTAssertEqual(closing.phase, .closed)
        XCTAssertNil(controller.workspaceURL)
        XCTAssertTrue(controller.recentProjects.contains(url))
        XCTAssertFalse(controller.isSwitchingWorkspace)
    }

    func testResistantProcessWaitsForExplicitForce() async throws {
        let (controller, url, project) = try await environment(command: "trap '' TERM; echo READY; while :; do /bin/sleep 1; done")
        controller.runner.start(project, workspaceURL: url)
        let ready = await waitUntil { controller.runner.state(for: project.id).output.contains("READY\n") }
        XCTAssertTrue(ready)
        let closing = ProjectClosing(controller: controller, url: url)
        let task = Task { await closing.confirm() }
        defer { task.cancel()
        controller.runner.terminateImmediately() }
        let canForce = await waitUntil { closing.canForce }
        XCTAssertTrue(canForce)
        XCTAssertTrue(closing.hasActiveProcesses, "no debe forzar automáticamente")
        XCTAssertEqual(controller.workspaceURL, url)
        XCTAssertTrue(controller.isSwitchingWorkspace)
        closing.force(project.id)
        let closed = await waitUntil { closing.phase == .closed }
        if !closed { task.cancel()
        controller.runner.terminateImmediately() }
        XCTAssertTrue(closed)
        XCTAssertFalse(controller.runner.hasActiveProcesses)
        XCTAssertNil(controller.workspaceURL)
        await task.value
    }

    func testCancellationLeavesProjectOpenAndReleasesTransition() async throws {
        let (controller, url, project) = try await environment(command: "trap '' TERM; echo READY; while :; do /bin/sleep 1; done")
        controller.runner.start(project, workspaceURL: url)
        let ready = await waitUntil { controller.runner.state(for: project.id).output.contains("READY\n") }
        XCTAssertTrue(ready)
        let closing = ProjectClosing(controller: controller, url: url)
        let task = Task { await closing.confirm() }
        let stopping = await waitUntil { closing.phase == .stopping }
        XCTAssertTrue(stopping)
        task.cancel()
        await task.value
        XCTAssertEqual(controller.workspaceURL, url)
        XCTAssertFalse(controller.isSwitchingWorkspace)
    }

    func testBackgroundChildWithClosedOutputStillCountsAsActive() async throws {
        let (controller, url, project) = try await environment(command: "/bin/sleep 30 >/dev/null 2>&1 & echo READY")
        controller.runner.start(project, workspaceURL: url)
        let ready = await waitUntil { controller.runner.state(for: project.id).output.contains("READY\n") }
        XCTAssertTrue(ready)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(controller.runner.hasActiveProcesses)
        let closing = ProjectClosing(controller: controller, url: url)
        let task = Task { await closing.confirm() }
        let closed = await waitUntil { closing.phase == .closed }
        if !closed { task.cancel()
        controller.runner.terminateImmediately() }
        await task.value
        XCTAssertTrue(closed)
        XCTAssertFalse(controller.runner.hasActiveProcesses)
    }
}
