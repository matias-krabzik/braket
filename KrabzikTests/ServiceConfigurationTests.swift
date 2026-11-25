import Darwin
import Foundation
@testable import Krabzik
import XCTest

@MainActor
final class ServiceConfigurationTests: XCTestCase {
    func testTrustPromptIncludesServiceCommandsStepsAndExternalWorkingDirectory() {
        var configuration = RunConfiguration()
        configuration.workingDirectory = "/tmp/braket-external-service"
        configuration.preScripts = ["nvm use v24"]
        let api = ServiceConfiguration(name: "API", command: "node server.js", configuration: configuration)
        let parent = CodeProject(name: "App", path: ".", kind: .node, command: "", services: [api])
        let workspace = Workspace(name: "Demo", projects: [parent])
        let prompt = TrustPrompt(for: workspace, at: URL(fileURLWithPath: "/Users/example/demo/Project.kzk"))
        XCTAssertEqual(prompt.commands.count, 1)
        XCTAssertTrue(prompt.commands[0].contains("App › API"))
        XCTAssertTrue(prompt.commands[0].contains("node server.js"))
        XCTAssertTrue(prompt.commands[0].contains("nvm use v24"))
        XCTAssertEqual(prompt.externalFolders, ["/tmp/braket-external-service"])
    }
    func testLegacyServiceRetainsIdentityConfigurationAndApproval() throws {
        var config = RunConfiguration()
        config.arguments = ["--port", "3000"]
        config.environment = ["NODE_ENV": "test"]
        config.workingDirectory = "backend"
        let parent = CodeProject(name: "App", path: ".", kind: .node, command: "npm run dev", runConfiguration: config)
        let service = try XCTUnwrap(parent.configuredServices.first)
        XCTAssertEqual(service.id, parent.id)
        XCTAssertEqual(service.name, "Principal")
        XCTAssertEqual(service.configuration, config)
        XCTAssertEqual(service.executionProject(in: parent).commandApproval, parent.commandApproval)
        XCTAssertEqual(parent.executionProjects, [parent])
    }
    func testDependenciesAreOrderedAndCyclesOrUnknownIDsRejected() throws {
        let api = ServiceConfiguration(name: "API", command: "node server.js")
        let client = ServiceConfiguration(name: "Cliente", command: "npm start", dependencies: [api.id])
        XCTAssertEqual(try ServicePlan.order([client, api], targets: [client.id]).map(\.id), [api.id, client.id])
        var cycle = api
        cycle.dependencies = [client.id]
        XCTAssertThrowsError(try ServicePlan.order([cycle, client], targets: [client.id]))
        var unknown = client
        unknown.dependencies = [UUID()]
        XCTAssertThrowsError(try ServicePlan.order([api, unknown], targets: [unknown.id]))
        XCTAssertThrowsError(try ServicePlan.order([api, api], targets: [api.id]))
    }
    func testNewExecutionFieldsRoundTripAndInvalidateApproval() throws {
        var config = RunConfiguration()
        config.shellPath = "/bin/bash"
        config.loadShellProfile = false
        config.initializeNVM = true
        config.preScripts = ["nvm use v24", "export DEMO=1"]
        config.stopOnPreScriptFailure = true
        let encoded = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(RunConfiguration.self, from: encoded), config)
        let plain = CodeProject(name: "API", path: ".", kind: .node, command: "node api.js")
        var modified = plain
        modified.runConfiguration = config
        XCTAssertNotEqual(modified.commandApproval, plain.commandApproval)
        config.preScripts = ["nvm use v22"]
        var other = modified
        other.runConfiguration = config
        XCTAssertNotEqual(other.commandApproval, modified.commandApproval)
        config.shellPath = "relative-shell"
        XCTAssertThrowsError(try config.validate())
    }
    func testPreScriptsKeepExportsAndNvmInTheSameShell() async throws {
        let root = try directory()
        let nvm = root.appendingPathComponent("nvm")
        try FileManager.default.createDirectory(at: nvm, withIntermediateDirectories: true)
        try Data("nvm() { export BRAKET_TEST_NODE=\"$2\"; }\n".utf8).write(to: nvm.appendingPathComponent("nvm.sh"))
        var config = RunConfiguration()
        config.loadShellProfile = false
        config.initializeNVM = true
        config.environment = ["NVM_DIR": nvm.path]
        config.preScripts = ["nvm use v24", "export BRAKET_TEST_STEP=ready"]
        let parent = CodeProject(name: "App", path: root.path, kind: .node, command: "")
        let service = ServiceConfiguration(name: "API", command: "printf '%s|%s' \"$BRAKET_TEST_NODE\" \"$BRAKET_TEST_STEP\"",
                                           configuration: config)
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        let execution = service.executionProject(in: parent)
        let url = root.appendingPathComponent("Test.kzk")
        runner.start(execution, workspaceURL: url)
        let run = runner.state(for: execution, workspaceURL: url)
        try await wait { !run.status.active }
        XCTAssertEqual(run.status, .exited(0))
        XCTAssertTrue(run.capturedOutput.contains("v24|ready"), run.output)
    }
    func testFailedPreScriptStopsTheMainCommandAndCanBeExplicitlyIgnored() async throws {
        let root = try directory()
        var config = RunConfiguration()
        config.loadShellProfile = false
        config.preScripts = ["false"]
        let parent = CodeProject(name: "App", path: root.path, kind: .files, command: "")
        var service = ServiceConfiguration(name: "API", command: "echo SHOULD_RUN", configuration: config)
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        let url = root.appendingPathComponent("Test.kzk")
        runner.start(service.executionProject(in: parent), workspaceURL: url)
        let run = runner.state(for: service.executionProject(in: parent), workspaceURL: url)
        try await wait { !run.status.active }
        XCTAssertNotEqual(run.status, .exited(0))
        XCTAssertFalse(run.capturedOutput.contains("SHOULD_RUN"))
        service.configuration.stopOnPreScriptFailure = false
        runner.start(service.executionProject(in: parent), workspaceURL: url)
        try await wait { !run.status.active }
        XCTAssertEqual(run.status, .exited(0))
        XCTAssertTrue(run.capturedOutput.contains("SHOULD_RUN"))
    }
    func testTwoServicesHaveIndependentProcessesAndStoppingOneKeepsTheOther() async throws {
        let root = try directory()
        let api = ServiceConfiguration(name: "API", command: "sleep 30")
        let client = ServiceConfiguration(name: "Cliente", command: "sleep 30")
        let parent = CodeProject(name: "App", path: root.path, kind: .node, command: "", services: [api, client])
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        let url = root.appendingPathComponent("Test.kzk")
        for execution in parent.executionProjects { runner.start(execution, workspaceURL: url) }
        let first = runner.state(for: api.executionProject(in: parent), workspaceURL: url)
        let second = runner.state(for: client.executionProject(in: parent), workspaceURL: url)
        XCTAssertNotEqual(first.processID, second.processID)
        runner.stop(first.id)
        try await wait { !first.status.active }
        XCTAssertTrue(second.status.active)
    }
    func testDependencyFailureDoesNotLaunchTheClient() async throws {
        let root = try directory()
        let api = ServiceConfiguration(name: "API", command: "exit 7")
        let client = ServiceConfiguration(name: "Cliente", command: "echo CLIENT_WAS_STARTED", dependencies: [api.id])
        let parent = CodeProject(name: "App", path: root.path, kind: .node, command: "", services: [api, client])
        let (controller, url) = try await workspace(root: root, parent: parent)
        defer { controller.runner.terminateImmediately() }
        controller.projects.startServices(parent, workspaceURL: url, serviceID: client.id)
        let run = controller.runner.state(for: client.executionProject(in: parent), workspaceURL: url)
        try await wait { !run.pendingRestart }
        if case .failed = run.status {} else { XCTFail("Expected dependency failure: \(run.status)") }
        XCTAssertFalse(run.capturedOutput.contains("CLIENT_WAS_STARTED"))
    }
    func testSavedServicesPreserveOtherChangesAndRejectConcurrentServiceEdits() async throws {
        let root = try directory()
        let parent = CodeProject(name: "App", path: root.path, kind: .node, command: "echo old")
        let (controller, url) = try await workspace(root: root, parent: parent)
        defer { controller.runner.terminateImmediately() }
        var external = try Workspace.read(from: url)
        external.name = "Renamed externally"
        try external.write(to: url)
        var edited = parent
        edited.services = [ServiceConfiguration(name: "API", command: "echo api"),
                           ServiceConfiguration(name: "Cliente", command: "echo client")]
        try controller.saveServices([edited], expected: [parent], at: url)
        let saved = try Workspace.read(from: url)
        XCTAssertEqual(saved.name, external.name)
        XCTAssertEqual(saved.projects.first?.services?.count, 2)
        XCTAssertEqual(saved.projects.first?.command, "")
        XCTAssertThrowsError(try controller.saveServices([edited], expected: [parent], at: url))
    }
    func testStartAllStartsAStoppedServiceEvenWhenTheLastServiceIsRunning() async throws {
        let root = try directory()
        let api = ServiceConfiguration(name: "API", command: "sleep 30")
        let client = ServiceConfiguration(name: "Cliente", command: "sleep 30")
        let parent = CodeProject(name: "App", path: root.path, kind: .node, command: "", services: [api, client])
        let (controller, url) = try await workspace(root: root, parent: parent)
        defer { controller.runner.terminateImmediately() }
        controller.runner.start(client.executionProject(in: parent), workspaceURL: url)
        let clientRun = controller.runner.state(for: client.executionProject(in: parent), workspaceURL: url)
        let pid = clientRun.processID
        controller.projects.startServices(parent, workspaceURL: url)
        let apiRun = controller.runner.state(for: api.executionProject(in: parent), workspaceURL: url)
        try await wait { apiRun.status.active }
        XCTAssertEqual(clientRun.processID, pid)
        XCTAssertTrue(clientRun.status.active)
    }
    func testForeignPortIsNotReadinessForOurDependency() async throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(descriptor, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        XCTAssertEqual(queried, 0)
        let root = try directory()
        var config = RunConfiguration()
        config.expectedPort = Int(UInt16(bigEndian: address.sin_port))
        let api = ServiceConfiguration(name: "API", command: "sleep 30", configuration: config, dependencyTimeout: 1)
        let client = ServiceConfiguration(name: "Cliente", command: "echo CLIENT_STARTED", dependencies: [api.id])
        let parent = CodeProject(name: "App", path: root.path, kind: .node, command: "", services: [api, client])
        let (controller, url) = try await workspace(root: root, parent: parent)
        defer { controller.runner.terminateImmediately() }
        controller.projects.startServices(parent, workspaceURL: url, serviceID: client.id)
        let run = controller.runner.state(for: client.executionProject(in: parent), workspaceURL: url)
        try await wait { !run.pendingRestart }
        if case .failed = run.status {} else { XCTFail("The foreign listener was mistaken for our service") }
        XCTAssertFalse(run.capturedOutput.contains("CLIENT_STARTED"))
    }
    func testDependenciesChangeExecutionApprovalAndSecretValuesAreWorkspaceBound() throws {
        let parent = CodeProject(name: "App", path: ".", kind: .node, command: "")
        var service = ServiceConfiguration(name: "API", command: "echo ok")
        let before = service.executionProject(in: parent).commandApproval
        service.dependencies = [UUID()]
        XCTAssertNotEqual(before, service.executionProject(in: parent).commandApproval)
        let store = ServiceEnvironmentStore()
        let variable = TerminalEnvironmentVariable(name: "TOKEN", secret: true, value: "service-test-secret")
        let url = URL(fileURLWithPath: "/tmp/services-\(UUID()).kzk")
        defer { store.remove([variable], serviceID: service.id, workspace: url) }
        try store.save([variable], serviceID: service.id, workspace: url)
        XCTAssertEqual(try store.hydrate([variable], serviceID: service.id, workspace: url).first?.value, variable.value)
        XCTAssertEqual(try store.hydrate([variable], serviceID: service.id,
                                         workspace: URL(fileURLWithPath: "/tmp/another.kzk")).first?.value, "")
        service.variables = [variable]
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(service), as: UTF8.self).contains(variable.value))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("braket-services-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func workspace(root: URL, parent: CodeProject) async throws -> (WorkspaceController, URL) {
        let url = root.appendingPathComponent("Test.kzk")
        try Workspace(name: "Services", projects: [parent]).write(to: url)
        let suite = "braket-services-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = WorkspaceController(defaults: defaults)
        controller.trust.markTrusted(url)
        controller.projects.confirmCommand = { _ in .once }
        await controller.openWorkspace(url)
        addTeardownBlock { @MainActor in
            controller.runner.terminateImmediately()
            defaults.removePersistentDomain(forName: suite)
        }
        return (controller, url)
    }
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The service did not reach the expected state")
    }
}
