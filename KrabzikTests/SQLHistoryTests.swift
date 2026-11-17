@testable import Krabzik
import XCTest

@MainActor
final class SQLHistoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("output-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func append(_ store: SQLHistoryStore, sql: String = "SELECT 1", status: String = "success") async {
        let token = await store.begin(sql: sql, configuration: DatabaseConnection(name: "Local"), database: "demo", source: "Consulta")
        await store.finish(token, status: status, elapsed: 0.025, rows: 1, affected: 2,
                           error: status == "error" ? "Syntax error" : "")
    }

    func testReopenPreservesDetailsAndRecoversUnfinishedQueries() async throws {
        let url = try directory().appendingPathComponent("output.sqlite")
        let store = SQLHistoryStore(url: url)
        let sql = "SELECT 'ñ 🦀' /* " + String(repeating: "x", count: 500) + " */"
        await append(store, sql: sql)
        await append(store, sql: "BAD SQL", status: "error")
        _ = await store.begin(sql: "SELECT SLEEP(100)", configuration: DatabaseConnection(), database: "demo", source: "Consulta")
        await store.close()
        let reopened = SQLHistoryStore(url: url)
        let entries = try await reopened.page()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].status, "interrupted")
        XCTAssertEqual(entries[1].error, "Syntax error")
        XCTAssertEqual(entries[2].rows, 1)
        XCTAssertEqual(entries[2].affected, "2")
        XCTAssertEqual(entries[2].elapsed, 0.025)
        XCTAssertLessThan(entries[2].sql.count, sql.count)
        let detail = try await reopened.detail(entries[2].id)
        XCTAssertEqual(detail?.sql, sql)
        await reopened.close()
    }

    func testKeysetPaginationDoesNotSkipOrDuplicateWhenNewRowsArrive() async throws {
        let store = SQLHistoryStore(url: try directory().appendingPathComponent("output.sqlite"))
        for index in 0 ..< 415 { await append(store, sql: "SELECT \(index)") }
        let first = try await store.page()
        XCTAssertEqual(first.count, 200)
        await append(store, sql: "SELECT 'new'")
        let second = try await store.page(before: first.last?.id)
        let third = try await store.page(before: second.last?.id)
        XCTAssertEqual(second.count, 200)
        XCTAssertEqual(third.count, 15)
        XCTAssertEqual(Set((first + second + third).map(\.id)).count, 415)
        XCTAssertEqual(third.last?.sql, "SELECT 0")
        await store.close()
    }

    func testSearchUsesAllStoredTextAndTreatsInputAsWords() async throws {
        let store = SQLHistoryStore(url: try directory().appendingPathComponent("output.sqlite"))
        await append(store, sql: "SELECT " + String(repeating: "x ", count: 300) + "FROM países")
        await append(store, sql: "UPDATE users SET name = 'Ana'")
        let accent = try await store.page(search: "PAISE")
        XCTAssertEqual(accent.count, 1)
        let scoped = try await store.page(search: "local demo users")
        XCTAssertEqual(scoped.count, 1)
        let missing = try await store.page(search: "no_such_table")
        XCTAssertTrue(missing.isEmpty)
        let escaped = try await store.page(search: "\" OR * : ( --")
        XCTAssertTrue(escaped.isEmpty)
        await store.close()
    }

    func testProjectsAreIsolatedAndReopeningFindsExistingHistory() async throws {
        let root = try directory()
        let output = SQLOutputController(root: root)
        let first = root.appendingPathComponent("first.kzk"), second = root.appendingPathComponent("second.kzk")
        output.configure(project: first)
        let store = try XCTUnwrap(output.store)
        await append(store, sql: "SELECT 'first'")
        output.configure(project: second)
        await output.reload()
        XCTAssertTrue(output.entries.isEmpty)
        // A late result still belongs to the store captured by its original operation.
        await append(store, sql: "SELECT 'late first'")
        await output.reload()
        XCTAssertTrue(output.entries.isEmpty)
        output.configure(project: first)
        await output.reload()
        XCTAssertEqual(output.entries.count, 2)
        let reloaded = SQLOutputController(root: root)
        reloaded.configure(project: first)
        await reloaded.reload()
        XCTAssertEqual(reloaded.entries.map(\.sql), output.entries.map(\.sql))
    }

    func testControllerPagesAndNewSearchDiscardsOldPages() async throws {
        let root = try directory(), output = SQLOutputController(root: try directory())
        output.configure(project: root.appendingPathComponent("project.kzk"))
        let store = try XCTUnwrap(output.store)
        for index in 0 ..< 205 { await append(store, sql: "SELECT \(index)") }
        await output.reload()
        XCTAssertEqual(output.entries.count, 200)
        XCTAssertTrue(output.hasMore)
        await output.loadMore()
        XCTAssertEqual(output.entries.count, 205)
        XCTAssertFalse(output.hasMore)
        output.search = "204"
        await output.reload()
        XCTAssertEqual(output.entries.map(\.sql), ["SELECT 204"])
        let entry = try XCTUnwrap(output.entries.first)
        await output.select(entry)
        await append(store, sql: "SELECT 'new'")
        await output.checkForUpdates()
        XCTAssertTrue(output.hasUpdates)
        XCTAssertEqual(output.selected?.id, entry.id)
    }

    func testStorageFailureIsVisibleAndDoesNotThrowIntoQueryExecution() async throws {
        let file = try directory().appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: file)
        let store = SQLHistoryStore(url: file.appendingPathComponent("output.sqlite"))
        await append(store)
        let failure = await store.writeError
        XCTAssertNotNil(failure)
        do { _ = try await store.page()
            XCTFail("Cannot read a database below a regular file")
        } catch {}
    }

    func testLogsSharesResultTabsAndRemainsAfterClosingTheLastResult() async throws {
        let qa = try QAHarness(self)
        await qa.openProject(try qa.makeProject(name: "Logs"))
        let document = try await qa.openScript("SELECT 1;")
        let result = QAFixtures.result(QAFixtures.connection())
        XCTAssertTrue(document.sqlExecution.begin(result))
        document.sqlExecution.receive(result)
        await qa.mount()
        await qa.assertControl("sql.logs.tab", title: "Logs")
        await qa.assertControl("sql.result.tab.0", title: "Consulta 1")
        try await qa.tap("sql.logs.tab")
        await qa.assertScreen("output")
        XCTAssertEqual(qa.controller.selectedDocumentID, document.id)
        XCTAssertEqual(document.sqlExecution.results.count, 1)
        try await qa.tap("sql.result.tab.0")
        await qa.assertScreen("grid.toolbar")
        await qa.assertScreen("output", present: false)
        try await qa.tap("sql.result.close.0")
        await qa.assertScreen("output")
        await qa.assertControl("sql.logs.tab", title: "Logs")
        XCTAssertTrue(document.sqlExecution.results.isEmpty)
        XCTAssertEqual(qa.controller.selectedDocumentID, document.id)
        qa.unmount()
    }

    func testOutputOpensWithoutSQLDocumentAndKeepsHistoryAcrossTabs() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Output")
        await qa.openProject(url)
        let store = try XCTUnwrap(qa.controller.database.output.store)
        await append(store, sql: "SELECT 'persisted'")
        await qa.mount()
        qa.controller.showOutput()
        await qa.assertScreen("output")
        let loaded = await qa.settle { qa.controller.database.output.entries.count == 1 }
        XCTAssertTrue(loaded)
        XCTAssertTrue(qa.controller.outputVisible)
        let document = try await qa.openScript("SELECT 2;")
        XCTAssertFalse(qa.controller.outputVisible)
        qa.controller.showOutput()
        await qa.assertScreen("output")
        XCTAssertEqual(qa.controller.selectedDocumentID, document.id)
        qa.unmount()
    }
}
