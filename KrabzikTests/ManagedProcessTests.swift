@testable import Krabzik
import XCTest

@MainActor
final class ManagedProcessTests: XCTestCase {
    func testManagerStartsIntegratedEvenAfterPreviouslyDetaching() throws {
        let suite = "braket-manager-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "processManager.detached")
        defaults.set(true, forKey: "processManager.visible")
        let manager = ProcessManagerPresentation(defaults: defaults)
        XCTAssertFalse(manager.isDetached)
    }

    func testDockPositionDefaultsToBottomAndIsRemembered() throws {
        let suite = "braket-process-dock-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = WorkspaceController(defaults: defaults)
        XCTAssertEqual(controller.processManager.dockPosition, .bottom)
        controller.database.resultsVisible = true
        controller.showProcessesPanel()
        XCTAssertTrue(controller.processesVisible)
        XCTAssertFalse(controller.database.resultsVisible)
        controller.moveProcessesPanel(to: .right)
        XCTAssertEqual(ProcessManagerPresentation(defaults: defaults).dockPosition, .right)
        controller.database.resultsVisible = true
        controller.showProcessesPanel()
        XCTAssertTrue(controller.database.resultsVisible)
        controller.moveProcessesPanel(to: .bottom)
        XCTAssertFalse(controller.database.resultsVisible)
        XCTAssertEqual(ProcessManagerPresentation(defaults: defaults).dockPosition, .bottom)
    }

    func testClosingWorkspaceOnlyOpensManagerForActiveProcesses() throws {
        let suite = "braket-manager-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = WorkspaceController(defaults: defaults)
        defer { controller.runner.terminateImmediately() }
        XCTAssertFalse(controller.processManager.keepProcessesVisible(controller))
        XCTAssertFalse(controller.processManager.isDetached)
        let run = controller.runner.state(for: CodeProject(name: "API", path: ".", kind: .files, command: "sleep 30"),
                                          workspaceURL: URL(fileURLWithPath: "/tmp/manager.kzk"))
        run.status = .running
        XCTAssertTrue(controller.processManager.keepProcessesVisible(controller))
        XCTAssertTrue(controller.processManager.isDetached)
        XCTAssertFalse(defaults.bool(forKey: "processManager.detached"), "Automatic detaching is not a preference")
        controller.processManager.dock(controller)
        run.status = .idle
    }

    func testManagerUsesAllSelectedThemeSurfaces() throws {
        let previous = Theme.settings
        defer { Theme.settings = previous }
        let suite = "braket-manager-theme-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Theme.settings = AppSettings(defaults: defaults)
        for theme in AppTheme.allCases {
            Theme.settings.theme = theme
            XCTAssertEqual(ProcessManagerAppearance.background, Theme.background)
            XCTAssertEqual(ProcessManagerAppearance.bar, Theme.bar)
            XCTAssertEqual(ProcessManagerAppearance.selection, Theme.accent.opacity(0.18))
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("El proceso no alcanzó el estado esperado")
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("braket-process-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testLegacyProjectKeepsItsCommandAndRequiresNoConfiguration() throws {
        let project = CodeProject(name: "API", path: ".", kind: .files, command: "npm run dev")
        let restored = try JSONDecoder().decode(CodeProject.self, from: JSONEncoder().encode(project))
        XCTAssertNil(restored.runConfiguration)
        XCTAssertEqual(restored.executionCommand, project.command)
        XCTAssertEqual(restored.commandApproval, project.command)
    }
    func testArgumentsEnvironmentAndWorkingDirectoryAreApplied() async throws {
        let root = try directory()
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        var project = CodeProject(name: "Echo", path: root.path, kind: .files,
                                  command: "printf '%s|%s|%s' \"$DEMO_VALUE\" \"$PWD\"")
        project.runConfiguration = RunConfiguration(arguments: ["a b; echo unsafe"], workingDirectory: "child",
                                                    environment: ["DEMO_VALUE": "hello world"])
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        let url = root.appendingPathComponent("test.kzk")
        runner.start(project, workspaceURL: url)
        let run = runner.state(for: project, workspaceURL: url)
        try await waitUntil { !run.status.active }
        XCTAssertTrue(run.output.contains("hello world|\(child.path)|a b; echo unsafe"))
        XCTAssertNotEqual(project.commandApproval, project.command)
    }
    func testCopiedProjectIdentifiersAreScopedToTheirWorkspace() async throws {
        let root = try directory()
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        let project = CodeProject(name: "API", path: root.path, kind: .files, command: "sleep 30")
        let firstURL = root.appendingPathComponent("first.kzk")
        let secondURL = root.appendingPathComponent("second.kzk")
        runner.start(project, workspaceURL: firstURL)
        runner.start(project, workspaceURL: secondURL)
        let first = runner.state(for: project, workspaceURL: firstURL)
        let second = runner.state(for: project, workspaceURL: secondURL)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.processID, second.processID)
        runner.stop(first.id)
        try await waitUntil { !first.status.active }
        XCTAssertTrue(second.status.active)
    }
    func testSwitchingWorkspaceKeepsProcessAndLogs() async throws {
        let root = try directory()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "braket-process-tests-\(UUID())"))
        defaults.set(false, forKey: "processManager.detached")
        let controller = WorkspaceController(defaults: defaults)
        defer { controller.runner.terminateImmediately() }
        controller.confirmTrust = { _ in .trust }
        controller.projects.confirmCommand = { _ in .once }
        let first = root.appendingPathComponent("first.kzk")
        let second = root.appendingPathComponent("second.kzk")
        let project = CodeProject(name: "API", path: root.path, kind: .files, command: "printf ready; sleep 30")
        try Workspace(name: "First", projects: [project]).write(to: first)
        try Workspace(name: "Second").write(to: second)
        await controller.openWorkspace(first)
        controller.toggleRun(project)
        let run = controller.runner.state(for: project, workspaceURL: first)
        try await waitUntil { run.output.contains("ready") }
        let pid = run.processID
        controller.session.dialogs.confirmStopProcesses = { XCTFail("Cambiar de proyecto no detiene los procesos")
            return false
        }
        await controller.openWorkspace(second)
        XCTAssertEqual(controller.workspaceURL, second)
        XCTAssertEqual(run.processID, pid)
        XCTAssertTrue(run.status.active)
        XCTAssertTrue(run.output.contains("ready"))
        let closingAllowed = await controller.prepareToQuit(keepingManagedProcesses: true)
        XCTAssertTrue(closingAllowed)
        XCTAssertEqual(run.processID, pid)
        XCTAssertTrue(run.status.active)
    }
    func testStoppingCancelsAutomaticRestart() async throws {
        let root = try directory()
        var project = CodeProject(name: "Failure", path: root.path, kind: .files, command: "exit 2")
        project.runConfiguration = RunConfiguration(restartPolicy: .onFailure)
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        let url = root.appendingPathComponent("test.kzk")
        runner.start(project, workspaceURL: url)
        let run = runner.state(for: project, workspaceURL: url)
        try await waitUntil { run.pendingRestart }
        runner.stop(run.id)
        let generation = run.generation
        try await Task.sleep(for: .milliseconds(2300))
        XCTAssertEqual(run.generation, generation)
        XCTAssertFalse(run.pendingRestart)
        XCTAssertFalse(run.status.active)
    }
    func testAutomaticPoliciesRequireApprovalOfTheNewConfiguration() {
        var project = CodeProject(name: "API", path: ".", kind: .files, command: "npm run dev")
        let original = project.commandApproval
        project.runConfiguration = RunConfiguration(startsAutomatically: true)
        XCTAssertNotEqual(project.commandApproval, original)
        project.runConfiguration = RunConfiguration(restartPolicy: .onFailure)
        XCTAssertNotEqual(project.commandApproval, original)
    }

    func testInspectorFindsAListeningPortOwnedByTheProcessGroup() async throws {
        let root = try directory()
        let script = "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',0)); s.listen(); " +
            "print(s.getsockname()[1],flush=True); time.sleep(30)"
        let project = CodeProject(name: "TCP", path: root.path, kind: .files,
                                  command: "/usr/bin/python3 -u -c " + Shell.quote(script))
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        let url = root.appendingPathComponent("ports.kzk")
        runner.start(project, workspaceURL: url)
        let run = runner.state(for: project, workspaceURL: url)
        try await waitUntil { Int(run.capturedOutput.trimmingCharacters(in: .whitespacesAndNewlines)) != nil }
        let port = try XCTUnwrap(Int(run.capturedOutput.trimmingCharacters(in: .whitespacesAndNewlines)))
        let inspection = ProcessInspection()
        let listeners = await inspection.listeners()
        XCTAssertTrue(listeners.contains { $0.port == port && $0.group == run.processID })
    }

}
