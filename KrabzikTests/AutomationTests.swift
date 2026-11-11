@testable import Krabzik
import XCTest

@MainActor
final class AutomationTests: XCTestCase {
    private func environment() throws -> (AutomationController, ProcessRunner, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let controller = AutomationController()
        let runner = ProcessRunner()
        controller.configure(workspace: root.appendingPathComponent("Test.kzk"), root: root)
        addTeardownBlock { @MainActor in
            controller.cancel()
            runner.terminateImmediately()
            try? FileManager.default.removeItem(at: AutomationStore(root: root).historyDirectory)
            try? FileManager.default.removeItem(at: root)
        }
        return (controller, runner, root)
    }

    private func wait(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        return predicate()
    }

    func testConfigurationRoundTripAndInvalidVariables() throws {
        let (_, _, root) = try environment()
        let store = AutomationStore(root: root)
        let file = AutomationFile(automations: [AutomationTemplates.script])
        try store.save(file)
        XCTAssertEqual(try store.load(), file)
        XCTAssertThrowsError(try AutomationFile(version: 99).validate())
        XCTAssertThrowsError(try AutomationFile.validateVariables([AutomationVariable(name: "BRAKET_RUN_DIR")]))
        XCTAssertThrowsError(try AutomationFile.validateVariables([AutomationVariable(name: "A"), AutomationVariable(name: "A")]))
    }

    func testChainOutputsAndLiteralParameters() async throws {
        let (controller, runner, root) = try environment()
        let parameters = [AutomationVariable(name: "VALUE", value: "$(touch injected); a ' b")]
        let automation = Automation(parameters: parameters, steps: [
            AutomationStep(command: "printf '%s' '{\"RESULT\":\"ready\"}' > \"$BRAKET_OUTPUT_FILE\""),
            AutomationStep(command: "printf '%s|%s' \"$BRAKET_OUTPUT_RESULT\" \"$BRAKET_INPUT_VALUE\" > result")
        ])
        controller.start(automation, parameters: parameters, workspace: root.appendingPathComponent("Test.kzk"), runner: runner)
        let finished = await wait { !controller.isRunning }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.execution?.phase, .succeeded)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("result"), encoding: .utf8), "ready|" + parameters[0].value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
        XCTAssertEqual(try AutomationStore(root: root).history().first?.phase, .succeeded)
    }

    func testFailureAndResumeDoNotRepeatSuccessfulSteps() async throws {
        let (controller, runner, root) = try environment()
        let url = root.appendingPathComponent("Test.kzk")
        let automation = Automation(steps: [
            AutomationStep(command: "echo once >> counter"),
            AutomationStep(command: "test -f allow || { echo 'Falta autorización local' >&2; exit 1; }", retryable: true),
            AutomationStep(command: "touch done")
        ])
        controller.start(automation, parameters: [], workspace: url, runner: runner)
        var finished = await wait { !controller.isRunning }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.execution?.phase, .failed)
        XCTAssertTrue(controller.currentRun?.output.contains("Falta autorización local") == true)
        XCTAssertTrue(controller.currentRun?.output.contains("Error en") == true)
        controller.selectStep(1)
        XCTAssertTrue(controller.currentRun?.output.contains("Falta autorización local") == true)
        XCTAssertTrue(controller.currentRun?.output.contains("Error en") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("done").path))
        try Data().write(to: root.appendingPathComponent("allow"))
        XCTAssertTrue(controller.canResume)
        controller.resume(workspace: url, runner: runner)
        finished = await wait { !controller.isRunning }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.execution?.phase, .succeeded)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("counter"), encoding: .utf8), "once\n")
    }

    func testConfirmationAndCancellation() async throws {
        let (controller, runner, root) = try environment()
        let automation = Automation(steps: [
            AutomationStep(command: "echo READY; sleep 30", requiresConfirmation: true),
            AutomationStep(command: "touch forbidden")
        ])
        controller.start(automation, parameters: [], workspace: root.appendingPathComponent("Test.kzk"), runner: runner)
        let waiting = await wait { controller.execution?.phase == .waiting }
        XCTAssertTrue(waiting)
        XCTAssertNil(controller.currentRun)
        controller.confirmStep()
        let running = await wait { controller.currentRun?.output.contains("READY") == true }
        XCTAssertTrue(running)
        controller.cancel()
        let finished = await wait { !controller.isRunning }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.execution?.phase, .cancelled)
        XCTAssertFalse(runner.hasActiveProcesses)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
    }

    func testInterruptedHistoryRequiresExplicitRetry() throws {
        let (controller, _, root) = try environment()
        let automation = Automation(steps: [AutomationStep(command: "echo hello", retryable: true)])
        let item = AutomationExecution(automation: automation, parameters: [], workspaceURL: root.appendingPathComponent("Test.kzk"),
                                       root: root, phase: .running, states: [.running])
        let store = AutomationStore(root: root)
        try store.save(item)
        let restored = try XCTUnwrap(store.history().first)
        XCTAssertEqual(restored.phase, .interrupted)
        controller.showHistory(restored)
        XCTAssertTrue(controller.canResume)
        XCTAssertFalse(controller.isRunning)
    }

    func testTimeoutStopsChain() async throws {
        let (controller, runner, root) = try environment()
        let automation = Automation(steps: [AutomationStep(command: "sleep 30", timeoutSeconds: 1)])
        controller.start(automation, parameters: [], workspace: root.appendingPathComponent("Test.kzk"), runner: runner)
        let finished = await wait { !controller.isRunning }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.execution?.phase, .failed)
        XCTAssertTrue(controller.message.contains("Tiempo agotado"))
        XCTAssertTrue(controller.currentRun?.output.contains("Tiempo agotado") == true)
        XCTAssertFalse(runner.hasActiveProcesses)
    }
}
