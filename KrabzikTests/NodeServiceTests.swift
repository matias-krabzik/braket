import Foundation
@testable import Krabzik
import XCTest

@MainActor final class NodeServiceTests: XCTestCase {
    func testDetectsOnceIncludingEmptyResultsAndCachesAcrossInstances() async throws {
        let domain = "braket.node-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = NodeInstallations(defaults: defaults, detect: { [] })
        await first.loadIfNeeded()
        let timestamp = first.detectedAt
        XCTAssertNotNil(timestamp)
        await first.loadIfNeeded()
        XCTAssertEqual(first.detectedAt, timestamp)
        let cached = NodeInstallations(defaults: defaults, detect: { XCTFail("Cached detection must not run")
        return [] })
        await cached.loadIfNeeded()
        XCTAssertEqual(cached.detectedAt, timestamp)
        await first.refresh()
        // The explicit refresh is allowed even when an empty result was cached.
        XCTAssertNotNil(first.detectedAt)
    }
    func testDetectionRunsOffMainAndExposesLoading() async throws {
        let domain = "braket.node-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = NodeInstallations(defaults: defaults, detect: {
            XCTAssertFalse(Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.15)
            return [NodeInstallation(tool: "node", path: "/node/bin/node", version: "v24")]
        })
        let refresh = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(store.detecting)
        await store.loadIfNeeded()
        await refresh.value
        XCTAssertFalse(store.detecting)
        XCTAssertEqual(store.installations.count, 1)
    }
    func testNodeArgumentsRemainLiteralAndPackageScriptsUseSelectedNode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("Node local no disponible") }
        try Data("process.stdout.write(process.argv[2])".utf8).write(to: root.appendingPathComponent("file name.js"))
        var node = NodeServiceConfiguration()
        node.executable = binary
        node.file = "file name.js"
        node.arguments = ["a 'quoted' $(echo shell)"]
        let service = ServiceConfiguration(name: "Node", node: node)
        try service.validate()
        XCTAssertEqual(try JSONDecoder().decode(ServiceConfiguration.self, from: JSONEncoder().encode(service)), service)
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", node.command]
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), node.arguments[0])
        node.kind = .package
        node.script = "dev"
        XCTAssertTrue(node.command.contains("export PATH="))
        XCTAssertTrue(node.command.contains("'npm' 'run' 'dev' '--'"))
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/npm") {
            let package: [String: Any] = ["scripts": ["dev": "node \"file name.js\""]]
            try JSONSerialization.data(withJSONObject: package).write(to: root.appendingPathComponent("package.json"))
            node.managerExecutable = "/opt/homebrew/bin/npm"
            let npm = Process()
            let output = Pipe()
            npm.executableURL = URL(fileURLWithPath: "/bin/zsh")
            npm.arguments = ["-c", node.command]
            npm.currentDirectoryURL = root
            npm.standardOutput = output
            npm.standardError = FileHandle.nullDevice
            try npm.run()
            npm.waitUntilExit()
            XCTAssertEqual(npm.terminationStatus, 0)
            let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertTrue(result.hasSuffix(node.arguments[0]), result)
        }
        node.manager = .yarn
        node.managerExecutable = "yarn"
        XCTAssertFalse(node.command.contains("'--'"))
    }
}
