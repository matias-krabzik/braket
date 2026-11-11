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
