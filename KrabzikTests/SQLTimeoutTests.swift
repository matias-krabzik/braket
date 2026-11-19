import Foundation
@testable import Krabzik
import XCTest

@MainActor final class SQLTimeoutTests: XCTestCase {
    func testApplicationProjectAndFilePrecedencePersistsAndCanReset() async throws {
        let qa = try QAHarness(self)
        let project = try qa.makeProject(name: "Timeout")
        await qa.openProject(project)
        let first = try await qa.openScript("SELECT 1", named: "one.sql")
        XCTAssertEqual(first.sqlExecution.timeoutSeconds, 60)
        XCTAssertEqual(first.sqlExecution.timeoutSource, "Aplicación")
        qa.controller.settings.defaultSQLTimeoutSeconds = 90
        XCTAssertEqual(first.sqlExecution.timeoutSeconds, 90)
        XCTAssertTrue(qa.controller.saveProjectSQLTimeout(120))
        XCTAssertEqual(first.sqlExecution.timeoutSeconds, 120)
        XCTAssertEqual(first.sqlExecution.timeoutSource, "Proyecto")
        first.sqlExecution.timeoutSeconds = 180
        qa.controller.settings.defaultSQLTimeoutSeconds = 240
        XCTAssertTrue(qa.controller.saveProjectSQLTimeout(300))
        XCTAssertEqual(first.sqlExecution.timeoutSeconds, 180)
        let second = try await qa.openScript("SELECT 2", named: "two.sql")
        XCTAssertEqual(second.sqlExecution.timeoutSeconds, 300)
        _ = await qa.controller.files.close(first)
        let reopened = try await qa.openScript("SELECT 1", named: "one.sql")
        XCTAssertEqual(reopened.sqlExecution.timeoutSeconds, 180)
        reopened.sqlExecution.resetTimeout()
        XCTAssertEqual(reopened.sqlExecution.timeoutSeconds, 300)
        XCTAssertTrue(qa.controller.saveProjectSQLTimeout(nil))
        XCTAssertEqual(reopened.sqlExecution.timeoutSeconds, 240)
        XCTAssertEqual(try Workspace.read(from: project).sqlTimeoutSeconds, nil)
        XCTAssertEqual(AppSettings(defaults: qa.defaults).defaultSQLTimeoutSeconds, 240)
    }

    func testPerFileValueDoesNotLeakToTheSameFileInAnotherProjectAndSurvivesNewController() async throws {
        let qa = try QAHarness(self)
        let firstProject = try qa.makeProject(name: "Uno"), secondProject = try qa.makeProject(name: "Dos")
        await qa.openProject(firstProject)
        let document = try await qa.openScript("SELECT 1", named: "shared.sql")
        document.sqlExecution.timeoutSeconds = 123
        let url = document.url
        await qa.openProject(secondProject)
        try await qa.controller.docs.open(url)
        XCTAssertEqual(qa.controller.docs.selected?.sqlExecution.timeoutSeconds, 60)
        let restored = qa.relaunch()
        await restored.openWorkspace(firstProject)
        try await restored.docs.open(url)
        XCTAssertEqual(restored.docs.selected?.sqlExecution.timeoutSeconds, 123)
    }

    func testOldWorkspaceAndInvalidApplicationPreferenceUseSixtySeconds() throws {
        let name = "TimeoutDefaults." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(-9, forKey: "defaultSQLTimeoutSeconds")
        XCTAssertEqual(AppSettings(defaults: defaults).defaultSQLTimeoutSeconds, 60)
        let old = try JSONDecoder().decode(Workspace.self, from: Data(#"{"version":1,"name":"Old"}"#.utf8))
        XCTAssertNil(old.sqlTimeoutSeconds)
        let execution = SQLExecution()
        XCTAssertEqual(execution.timeoutSeconds, 60)
        execution.timeoutSeconds = 9000
        XCTAssertEqual(execution.timeoutSeconds, 3600)
        execution.timeoutSeconds = -1
        XCTAssertEqual(execution.timeoutSeconds, 1)
        execution.resetTimeout()
        XCTAssertEqual(execution.timeoutSeconds, 60)
    }
    func testRunningExecutionKeepsItsCapturedLimitAndNextExecutionInheritsChanges() async throws {
        let qa = try QAHarness(self)
        let project = try qa.makeProject(name: "En curso")
        await qa.openProject(project)
        let document = try await qa.openScript("SELECT 1", named: "consulta.sql")
        document.sqlExecution.runningTimeoutSeconds = document.sqlExecution.timeoutSeconds
        qa.controller.settings.defaultSQLTimeoutSeconds = 120
        XCTAssertEqual(document.sqlExecution.timeoutSeconds, 60)
        document.sqlExecution.finish(error: nil)
        XCTAssertEqual(document.sqlExecution.timeoutSeconds, 120)
    }

    func testTimeoutSurvivesSavingADraftAndReopeningTheSavedFile() async throws {
        let qa = try QAHarness(self)
        let project = try qa.makeProject(name: "Guardar borrador")
        await qa.openProject(project)
        let draft = try qa.controller.docs.createDraft(name: "consulta.sql", text: "SELECT 1")
        draft.sqlExecution.timeoutSeconds = 137
        let destination = qa.root.appendingPathComponent("guardado.sql")
        let saved = try qa.controller.docs.saveDraft(draft, to: destination)
        XCTAssertEqual(saved.sqlExecution.timeoutSeconds, 137)
        _ = await qa.controller.files.close(saved)
        try await qa.controller.docs.open(destination)
        XCTAssertEqual(qa.controller.docs.selected?.sqlExecution.timeoutSeconds, 137)
    }

    func testProjectRelocationKeepsTimeoutAndRebindsFurtherChangesToTheNewLocation() async throws {
        let qa = try QAHarness(self)
        let project = try qa.makeProject(name: "Mover proyecto")
        await qa.openProject(project)
        let document = try await qa.openScript("SELECT 1", named: "consulta.sql")
        document.sqlExecution.timeoutSeconds = 123
        let destination = qa.root.appendingPathComponent("Movido.kzk")
        let moved = await qa.controller.relocateWorkspace(to: destination)
        XCTAssertTrue(moved)
        XCTAssertEqual(document.sqlExecution.timeoutSeconds, 123)
        document.sqlExecution.timeoutSeconds = 211
        let restored = qa.relaunch()
        await restored.openWorkspace(destination)
        try await restored.docs.open(document.url)
        XCTAssertEqual(restored.docs.selected?.sqlExecution.timeoutSeconds, 211)
    }

    private actor Results {
        var count = 0
        func append(_ result: SQLResult) { if !result.columns.isEmpty { count += 1 } }
    }
    func testRealMySQLTimeoutAppliesToEachStatementRatherThanWholeFile() async throws {
        let port = try QAFixtures.mysqlPort()
        var config = DatabaseConnection()
        config.port = port
        config.database = "krabzik_qa"
        config.tls = .disabled
        let client = MySQLClient(), sink = Results()
        do {
            _ = try await client.execute("SELECT SLEEP(0.6); SELECT SLEEP(0.6); SELECT SLEEP(0.6);", startingLine: 1,
                                         configuration: config, password: "", operation: UUID(), timeoutSeconds: 1) {
                await sink.append($0)
            }
            let count = await sink.count
            XCTAssertEqual(count, 3)
        } catch { await client.shutdown()
        throw error }
        await client.shutdown()
    }

}
