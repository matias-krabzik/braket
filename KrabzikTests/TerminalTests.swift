import AppKit
@testable import Krabzik
import XCTest

@MainActor
final class TerminalTests: XCTestCase {
    func testEnvironmentPrecedenceAndValidation() throws {
        let shared = TerminalEnvironmentVariable(name: "DEMO", value: "project")
        let own = TerminalEnvironmentVariable(name: "DEMO", value: "terminal")
        let merged = TerminalEnvironment.merge(system: ["DEMO": "system", "PATH": "/bin"], project: [shared], terminal: [own])
        XCTAssertEqual(merged["DEMO"], "terminal")
        XCTAssertEqual(merged["PATH"], "/bin")
        XCTAssertEqual(merged["TERM"], "xterm-256color")
        XCTAssertThrowsError(try TerminalEnvironment.validate([shared, shared]))
        XCTAssertThrowsError(try TerminalEnvironment.validate([TerminalEnvironmentVariable(name: "A=B", value: "x")]))
        XCTAssertThrowsError(try TerminalEnvironment.validate([TerminalEnvironmentVariable(name: "A", value: "\0")]))
    }
    func testSecretsNeverAppearInSerializedMetadata() throws {
        let variable = TerminalEnvironmentVariable(name: "TOKEN", secret: true, value: "never-write-this-value")
        let tab = TerminalTabConfiguration(directory: "/tmp", variables: [variable])
        let config = TerminalProjectConfiguration(tabs: [tab], selectedID: tab.id, variables: [variable], visible: true)
        let data = try JSONEncoder().encode(config)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(variable.value))
        let restored = try JSONDecoder().decode(TerminalProjectConfiguration.self, from: data)
        XCTAssertEqual(restored.tabs.first?.id, tab.id)
        XCTAssertEqual(restored.tabs.first?.directory, "/tmp")
        XCTAssertEqual(restored.variables.first?.value, "")
    }
    func testTabsRestorePerProjectWithoutLaunchingCommands() throws {
        let suite = "terminal-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = URL(fileURLWithPath: "/tmp/first.kzk")
        let second = URL(fileURLWithPath: "/tmp/second.kzk")
        let manager = TerminalManager(defaults: defaults)
        manager.openProject(first)
        manager.addTab(first)
        manager.addTab(first)
        let tabs = manager.configuration(for: first).tabs
        manager.select(tabs[0].id, for: first)
        manager.openProject(second)
        XCTAssertTrue(manager.configuration(for: second).tabs.isEmpty)
        let next = TerminalManager(defaults: defaults)
        next.openProject(first)
        XCTAssertEqual(next.configuration(for: first).tabs.map(\.id), tabs.map(\.id))
        XCTAssertEqual(next.configuration(for: first).selectedID, tabs[0].id)
        XCTAssertTrue(next.visible)
        XCTAssertTrue(next.sessions.isEmpty)
        manager.stopAll()
        next.stopAll()
    }
    func testProjectAndTerminalValuesPersistInKeychain() throws {
        let suite = "terminal-keychain-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(fileURLWithPath: "/tmp/\(UUID()).kzk")
        let preferences = TerminalPreferences(defaults: defaults)
        let shared = TerminalEnvironmentVariable(name: "BR_TEST_SHARED", secret: true, value: "shared-test-value")
        let own = TerminalEnvironmentVariable(name: "BR_TEST_SHARED", value: "terminal-test-value")
        defer { preferences.removeValues([shared, own]) }
        let tab = TerminalTabConfiguration(directory: "/private/tmp", variables: [own])
        try preferences.saveValues([shared, own])
        try preferences.save(TerminalProjectConfiguration(tabs: [tab], variables: [shared]), for: url)
        let restored = try preferences.load(url)
        XCTAssertEqual(restored.variables.first?.value, shared.value)
        XCTAssertEqual(restored.tabs.first?.variables.first?.value, own.value)
        let metadata = try XCTUnwrap(defaults.data(forKey: "terminal.project." + url.path))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains(shared.value))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains(own.value))
        let other = try preferences.load(URL(fileURLWithPath: "/tmp/another-project.kzk"))
        XCTAssertTrue(other.variables.isEmpty)
    }

    func testDescendantsIncludeBackgroundGrandchildren() {
        let rows = [TerminalInspection.Child(pid: 2, parent: 1, group: 2, command: "zsh"),
                    TerminalInspection.Child(pid: 3, parent: 2, group: 3, command: "npm"),
                    TerminalInspection.Child(pid: 4, parent: 3, group: 3, command: "node"),
                    TerminalInspection.Child(pid: 5, parent: 1, group: 5, command: "other")]
        XCTAssertEqual(Set(TerminalInspection.descendants(of: 2, in: rows).map(\.pid)), [3, 4])
    }
    func testPTYTracksDirectoryAndProtectsAnActiveService() async throws {
        let suite = "terminal-pty-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = URL(fileURLWithPath: "/tmp/pty-test.kzk")
        let manager = TerminalManager(defaults: defaults)
        defer { manager.stopAll() }
        manager.openProject(url)
        manager.addTab(url)
        let tab = try XCTUnwrap(manager.configuration(for: url).tabs.first)
        let session = manager.activate(tab, project: url, trusted: true)
        XCTAssertTrue(session.running)
        let terminal = try XCTUnwrap(session.view)
        terminal.send(txt: "cd /private/tmp; sleep 30\n")
        let inspector = TerminalInspection()
        var snapshot = TerminalInspection.Snapshot()
        for _ in 0..<100 {
            snapshot = await inspector.snapshot(pid: terminal.process.shellPid)
            if snapshot.children.contains(where: { $0.command.contains("sleep") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(snapshot.children.contains { $0.command.contains("sleep") })
        XCTAssertEqual(snapshot.directory, "/private/tmp")
        var asked = false
        manager.approveClosing = { _ in asked = true
            return false }
        await manager.close(tab, project: url)
        XCTAssertTrue(asked)
        XCTAssertNotNil(manager.sessions[tab.id])
        XCTAssertTrue(session.running)
        manager.setVisible(false, for: url)
        XCTAssertTrue(session.running, "Minimizing must keep the shell and service")
        manager.approveClosing = { _ in true }
        await manager.close(tab, project: url)
        XCTAssertNil(manager.sessions[tab.id])
        XCTAssertTrue(manager.configuration(for: url).tabs.isEmpty)
    }
}
