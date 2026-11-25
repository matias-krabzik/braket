import Foundation
@testable import Krabzik
import XCTest

@MainActor final class PHPServiceTests: XCTestCase {
    func testLegacyServiceDecodesWithoutPHP() throws {
        let data = try JSONEncoder().encode(ServiceConfiguration(name: "Legacy", command: "npm start"))
        XCTAssertNil(try JSONDecoder().decode(ServiceConfiguration.self, from: data).php)
    }
    func testArtisanUsesSelectedInterpreterAndOnePort() throws {
        var php = PHPServiceConfiguration()
        php.php = "/opt/php 8/bin/php"
        php.port = 8123
        php.interpreterOptions = ["-d", "memory_limit=512M"]
        let service = ServiceConfiguration(name: "API", php: php)
        let execution = service.executionProject(in: CodeProject(name: "App", path: ".", kind: .php, command: ""))
        XCTAssertEqual(execution.runConfiguration?.expectedPort, 8123)
        XCTAssertEqual(php.tokens, [php.php, "-d", "memory_limit=512M", "artisan", "serve", "--host=127.0.0.1", "--port=8123"])
        try service.validate()
        XCTAssertEqual(try JSONDecoder().decode(ServiceConfiguration.self, from: JSONEncoder().encode(service)), service)
    }
    func testComposerUsesSelectedFileAndForwardsArguments() {
        var php = PHPServiceConfiguration()
        php.kind = .composer
        php.composer = "composer.phar"
        php.composerFile = "config/composer.dev.json"
        php.arguments = ["hello world", "$(touch /tmp/never)"]
        XCTAssertEqual(php.tokens,
                       [
                           "env",
                           "COMPOSER=config/composer.dev.json",
                           "php",
                           "composer.phar",
                           "run-script",
                           "--timeout=0",
                           "dev",
                           "--",
                           "hello world",
                           "$(touch /tmp/never)"
                       ])
        XCTAssertNil(php.effectivePort)
    }
    func testContainerSettingsAndEnvironmentAreIsolated() {
        var php = PHPServiceConfiguration()
        php.environment = .docker
        php.kind = .server
        php.publishedPort = 8080
        let id = UUID()
        let command = php.command(id: id, environmentKeys: ["APP_ENV"])
        XCTAssertTrue(command.contains("setsid"))
        XCTAssertTrue(command.contains(id.uuidString.lowercased()))
        XCTAssertTrue(command.contains("APP_ENV"))
        XCTAssertTrue(command.contains("EXIT"))
        XCTAssertEqual(php.effectivePort, 8080)
        php.environment = .sail
        XCTAssertEqual(php.containerPrefix, ["vendor/bin/sail"])
        php.environment = .docker
        php.useTemporaryContainer = true
        XCTAssertTrue(php.command(id: id).contains("--service-ports"))
    }
    func testDockerExecForwardsEnvironmentAndStopsOnlyItsExecution() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/local/bin/docker") else { throw XCTSkip("Docker no disponible") }
        func docker(_ args: [String], at root: URL) throws -> (Int32, String) {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
            process.arguments = args
            process.currentDirectoryURL = root
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("braket-php-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard try docker(["image", "inspect", "sail-8.5/app:latest"], at: root).0 == 0
            else { throw XCTSkip("Imagen Sail de prueba no disponible") }
        let compose = "services:\n  php:\n    image: sail-8.5/app:latest\n    entrypoint: []\n" +
            "    command: [sleep, infinity]\n    volumes:\n      - './:/app'\n"
        try Data(compose.utf8).write(to: root.appendingPathComponent("compose.yaml"))
        defer { _ = try? docker(["compose", "down", "--remove-orphans"], at: root) }
        XCTAssertEqual(try docker(["compose", "up", "-d"], at: root).0, 0)
        let script = "<?php $child = proc_open(['php', '-r', 'sleep(120);'], [], $pipes); " +
            "echo getenv('BRAKET_PHP_TEST'); while (true) { sleep(1); }"
        try Data(script.utf8).write(to: root.appendingPathComponent("test.php"))
        var php = PHPServiceConfiguration()
        php.environment = .docker
        php.kind = .composer
        let composer: [String: Any] = ["scripts": ["dev": "php test.php"]]
        try JSONSerialization.data(withJSONObject: composer).write(to: root.appendingPathComponent("composer.json"))
        let service = ServiceConfiguration(name: "Docker PHP", php: php)
        var execution = service.executionProject(in: CodeProject(name: "App", path: root.path, kind: .php, command: ""))
        execution.runConfiguration?.environment = ["BRAKET_PHP_TEST": "ready"]
        execution.command = php.command(id: service.id, environmentKeys: ["BRAKET_PHP_TEST"])
        let runner = ProcessRunner()
        let url = root.appendingPathComponent("Test.kzk")
        let run = runner.state(for: execution, workspaceURL: url)
        runner.start(execution, workspaceURL: url)
        defer { runner.stop(run.id) }
        for _ in 0..<100 { if run.output.contains("ready") { break }
        try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(run.output.contains("ready"), run.output)
        runner.stop(run.id)
        for _ in 0..<50 { if !run.status.active { break }
        try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(run.status.active)
        let marker = "/tmp/braket-" + service.id.uuidString.lowercased() + ".pid"
        XCTAssertEqual(try docker(["compose", "exec", "-T", "php", "test", "!", "-e", marker], at: root).0, 0)
        XCTAssertEqual(try docker(["compose", "exec", "-T", "php", "true"], at: root).0, 0)
    }
    func testScriptArgumentsAreLiteralInActualPHP() throws {
        let phpPath = "/opt/homebrew/opt/php@8.4/bin/php"
        guard FileManager.default.isExecutableFile(atPath: phpPath) else { throw XCTSkip("PHP local no disponible") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<?php echo $argv[1];".utf8).write(to: root.appendingPathComponent("test file.php"))
        var php = PHPServiceConfiguration()
        php.php = phpPath
        php.script = "test file.php"
        php.arguments = ["a 'quote' $(echo injected)"]
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", php.command(id: UUID())]
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), php.arguments[0])
    }
}
