import Foundation
@testable import Krabzik
import XCTest

@MainActor final class SQLResultTabsTests: XCTestCase {
    private func populated() -> SQLExecution {
        let execution = SQLExecution()
        for index in 1...5 {
            var result = SQLResult(statement: index, line: index)
            result.sql = "SELECT \(index)"
            result.columns = ["id"]
            result.rows = [[String(index)]]
            execution.receive(result)
        }
        execution.selectedResultID = execution.results[2].id
        return execution
    }

    func testCloseLeftRightOthersAllAndUnpinnedKeepTheExpectedResults() {
        for (action, expected) in [(SQLResultTabAction.left, [3, 4, 5]), (.right, [1, 2, 3]),
                                   (.others, [3]), (.current, [1, 2, 4, 5]), (.all, []), (.unpinned, [2])] {
            let execution = populated()
            let anchor = execution.results[2].id
            execution.pinned.insert(execution.results[1].id)
            for result in execution.results { _ = execution.draft(for: result) }
            XCTAssertTrue(execution.closeTabs(action, relativeTo: anchor))
            XCTAssertEqual(execution.results.map(\.statement), expected)
            XCTAssertTrue(Set(execution.drafts.keys).isSubset(of: Set(execution.results.map(\.id))))
            XCTAssertTrue(execution.pinned.isSubset(of: Set(execution.results.map(\.id))))
            if action == .current { XCTAssertEqual(execution.selectedResult?.statement, 4) }
            if action == .all { XCTAssertNil(execution.selectedResultID) }
        }
    }

    func testCancelBulkCloseKeepsEveryTabDraftPinAndSelection() {
        let execution = populated()
        let ids = execution.results.map(\.id), selected = execution.selectedResultID
        execution.pinned.insert(ids[1])
        for result in execution.results.prefix(2) {
            execution.draft(for: result).changes[SQLCell(row: 0, column: 0)] = .text("nuevo")
        }
        let original = SQLResultDraft.confirmDiscardChanges
        defer { SQLResultDraft.confirmDiscardChanges = original }
        var prompts = 0
        SQLResultDraft.confirmDiscardChanges = { _ in prompts += 1
        return prompts == 1 }
        XCTAssertFalse(execution.closeTabs(.all))
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(execution.results.map(\.id), ids)
        XCTAssertEqual(execution.selectedResultID, selected)
        XCTAssertEqual(execution.pinned, [ids[1]])
        XCTAssertEqual(execution.drafts.values.filter(\.hasChanges).count, 2)
    }

    func testLoadingAndSendingCannotCloseAndInvalidAnchorsDoNothing() {
        let execution = populated()
        execution.results[0].isLoading = true
        XCTAssertFalse(execution.canCloseTabs(.all))
        XCTAssertFalse(execution.closeTabs(.all))
        execution.results[0].isLoading = false
        let draft = execution.draft(for: execution.results[0])
        draft.sending = true
        XCTAssertFalse(execution.closeTabs(.unpinned))
        draft.sending = false
        XCTAssertFalse(execution.canCloseTabs(.left, relativeTo: execution.results[0].id))
        XCTAssertFalse(execution.canCloseTabs(.right, relativeTo: execution.results.last?.id))
        XCTAssertTrue(execution.closeTabs(.others, relativeTo: UUID()))
        XCTAssertEqual(execution.results.count, 5)
    }

    func testFileExecutionClosesOnlyUnpinnedAfterWriteGuardAndBeforeSendingSQL() async throws {
        let qa = try QAHarness(self)
        let project = try qa.makeProject(name: "Resultados")
        await qa.openProject(project)
        let connection = try await qa.addConnection(QAFixtures.connection("Local", policy: .readOnly))
        let document = try await qa.openScript("DELETE FROM t;", named: "consulta.sql", connection: connection)
        let execution = document.sqlExecution
        let old = populated()
        execution.results = old.results
        execution.selectedResultID = old.selectedResultID
        let pinned = execution.results[1].id
        execution.pinned.insert(pinned)
        qa.controller.executeSQLFile()
        XCTAssertEqual(execution.results.count, 5, "Rechazar una escritura no cierra resultados")
        document.text = "SELECT 10; SELECT 11;"
        qa.controller.executeSQLFile()
        XCTAssertEqual(execution.results.count, 2, "Conserva el fijado y agrega la primera consulta nueva")
        XCTAssertEqual(execution.results.first?.id, pinned)
        XCTAssertTrue(execution.pinned.contains(pinned))
        qa.controller.database.cancel(execution)
        await qa.controller.database.client.shutdown()
    }

    func testCancellingDraftDiscardAbortsFullFileWithoutClosingAnyResults() async throws {
        let qa = try QAHarness(self)
        let project = try qa.makeProject(name: "Borradores")
        await qa.openProject(project)
        let connection = try await qa.addConnection(QAFixtures.connection("Local"))
        let document = try await qa.openScript("SELECT 10;", named: "consulta.sql", connection: connection)
        document.sqlExecution.results = populated().results
        let ids = document.sqlExecution.results.map(\.id)
        document.sqlExecution.draft(for: document.sqlExecution.results[0]).changes[SQLCell(row: 0, column: 0)] = .text("nuevo")
        let original = SQLResultDraft.confirmDiscardChanges
        defer { SQLResultDraft.confirmDiscardChanges = original }
        SQLResultDraft.confirmDiscardChanges = { _ in false }
        qa.controller.executeSQLFile()
        XCTAssertEqual(document.sqlExecution.results.map(\.id), ids)
        XCTAssertFalse(document.sqlExecution.isRunning)
        qa.assertNoEvent("sql.execute.begin")
    }

    func testFullFileCanReplaceTwoHundredOldTabsWithoutHittingTheirBudget() async throws {
        let qa = try QAHarness(self)
        let project = try qa.makeProject(name: "Presupuesto")
        await qa.openProject(project)
        let connection = try await qa.addConnection(QAFixtures.connection("Local"))
        let document = try await qa.openScript("SELECT 999;", named: "consulta.sql", connection: connection)
        for index in 1...200 {
            var result = SQLResult(statement: index, line: index)
            result.sql = "SELECT \(index)"
            document.sqlExecution.receive(result)
        }
        qa.controller.executeSQLFile()
        XCTAssertTrue(document.sqlExecution.isRunning)
        XCTAssertEqual(document.sqlExecution.results.count, 1)
        qa.controller.database.cancel(document.sqlExecution)
        await qa.controller.database.client.shutdown()
    }

    func testPinControlWorksThroughTheRealResultTabs() async throws {
        let qa = try QAHarness(self)
        let project = try qa.makeProject(name: "Pestañas")
        await qa.openProject(project)
        let document = try await qa.openScript("SELECT 1", named: "consulta.sql")
        let source = populated()
        document.sqlExecution.results = source.results
        document.sqlExecution.selectedResultID = source.selectedResultID
        qa.controller.database.resultsVisible = true
        await qa.mount()
        try await qa.tap("sql.result.pin.0")
        let id = try XCTUnwrap(document.sqlExecution.results.first?.id)
        XCTAssertTrue(document.sqlExecution.pinned.contains(id))
        try await qa.tap("sql.result.pin.0")
        XCTAssertFalse(document.sqlExecution.pinned.contains(id))
        try await qa.tap("sql.result.close.0")
        XCTAssertEqual(document.sqlExecution.results.count, 4)
        XCTAssertFalse(document.sqlExecution.results.contains { $0.id == id })
    }
}
