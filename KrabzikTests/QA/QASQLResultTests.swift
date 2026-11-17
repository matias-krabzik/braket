@testable import Krabzik
import XCTest

/// Suite SQL del catálogo, parte de resultados: las pestañas del panel inferior.
///
/// Son escenarios sobre `SQLExecution`, que es el estado que la vista muestra: cuántas
/// pestañas hay, cuál se reusa, cuál se conserva fijada y qué queda cuando algo falla.
@MainActor
final class QASQLResultTests: XCTestCase {
    private func result(_ connection: DatabaseConnection, sql: String, rows: [[String?]] = [["1"]],
                        index: Int = 0) -> SQLResult {
        var result = QAFixtures.result(connection, columns: ["id"], rows: rows, sql: sql)
        result.resultIndex = index
        return result
    }

    /// SQL-05
    func testEachStatementGetsItsOwnResultTab() async throws {
        _ = try QAHarness(self)
        let connection = QAFixtures.connection()
        let execution = SQLExecution()
        for (index, sql) in ["SELECT 1", "SELECT 2", "SELECT 3"].enumerated() {
            var pending = result(connection, sql: sql)
            pending.statement = index + 1
            XCTAssertTrue(execution.begin(pending))
            execution.receive(pending)
        }
        XCTAssertEqual(execution.results.count, 3)
        XCTAssertEqual(execution.results.map(\.sql), ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    /// SQL-06
    func testRepeatingAQueryReusesItsTab() async throws {
        _ = try QAHarness(self)
        let connection = QAFixtures.connection()
        let execution = SQLExecution()
        var first = result(connection, sql: "SELECT id FROM personas", rows: [["1"]])
        XCTAssertTrue(execution.begin(first))
        execution.receive(first)
        let id = execution.selectedResultID
        first.rows = [["2"]]
        XCTAssertTrue(execution.begin(first))
        execution.receive(first)
        XCTAssertEqual(execution.results.count, 1, "la misma consulta reusa su pestaña")
        XCTAssertEqual(execution.selectedResultID, id)
        XCTAssertEqual(execution.selectedResult?.rows, [["2"]])
    }

    /// SQL-07
    func testAPinnedTabIsNeverReused() async throws {
        _ = try QAHarness(self)
        let connection = QAFixtures.connection()
        let execution = SQLExecution()
        let query = result(connection, sql: "SELECT id FROM personas")
        XCTAssertTrue(execution.begin(query))
        execution.receive(query)
        let pinned = try XCTUnwrap(execution.selectedResultID)
        execution.pinned.insert(pinned)
        XCTAssertTrue(execution.begin(query))
        execution.receive(query)
        XCTAssertEqual(execution.results.count, 2, "la fijada se conserva y la nueva va aparte")
        XCTAssertTrue(execution.results.contains { $0.id == pinned })
    }

    /// SQL-08
    func testClosingAResultWithPendingChangesAsksFirst() async throws {
        let qa = try QAHarness(self)
        let connection = QAFixtures.connection()
        let execution = SQLExecution()
        let query = result(connection, sql: "SELECT id, nombre FROM personas")
        XCTAssertTrue(execution.begin(query))
        execution.receive(query)
        let stored = try XCTUnwrap(execution.results.first)
        let draft = execution.draft(for: stored)
        draft.configure(QAFixtures.table())
        draft.changes[SQLCell(row: 0, column: 0)] = .text("cambiado")
        XCTAssertTrue(draft.hasChanges)

        qa.script.discardGridChanges = false
        XCTAssertFalse(draft.confirmDiscard(), "con cambios pendientes se pregunta")
        await qa.assertEvent("dialog.grid.discardChanges", ["answer": "cancel"])
        XCTAssertFalse(execution.begin(query), "si el usuario cancela, no se pisa el resultado")

        qa.script.discardGridChanges = true
        XCTAssertTrue(draft.confirmDiscard())
        await qa.assertEvent("dialog.grid.discardChanges", ["answer": "discard"])
    }

    /// SQL-09
    func testAFailedQueryLeavesARetryableTab() async throws {
        _ = try QAHarness(self)
        let connection = QAFixtures.connection()
        let execution = SQLExecution()
        let query = result(connection, sql: "SELECT SLEEP(20)")
        XCTAssertTrue(execution.begin(query))
        XCTAssertEqual(execution.selectedResult?.isLoading, true)
        execution.finish(error: "Se agotó el tiempo de la consulta.")
        XCTAssertEqual(execution.selectedResult?.isLoading, false, "no queda el spinner girando")
        XCTAssertEqual(execution.selectedResult?.error, "Se agotó el tiempo de la consulta.")
        XCTAssertEqual(execution.selectedResult?.sql, "SELECT SLEEP(20)", "el SQL queda para reintentar")
    }

    /// SQL-17
    func testPaginationEnablesTheRightArrows() async throws {
        _ = try QAHarness(self)
        let paginable = SQLPagination("SELECT id FROM personas", page: 0, noBackslashEscapes: false)
        XCTAssertNotNil(paginable, "un SELECT sin LIMIT se pagina")
        XCTAssertNil(SQLPagination("SELECT id FROM personas LIMIT 10", page: 0, noBackslashEscapes: false),
                     "con LIMIT propio se respeta la consulta")
        var page = SQLPage(index: 0)
        page.totalRows = 250
        page.hasNext = true
        XCTAssertEqual(page.count, 3, "250 filas son tres páginas de 100")
        XCTAssertEqual(page.index, 0, "en la primera página, «anterior» va deshabilitado")
        var last = SQLPage(index: 2)
        last.totalRows = 250
        last.hasNext = false
        XCTAssertFalse(last.hasNext, "en la última, «siguiente» va deshabilitado")
        XCTAssertGreaterThan(last.index, 0)
    }

    /// SQL-18
    func testTheResultBudgetAsksToCloseTabs() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        let connection = try await qa.addConnection(QAFixtures.connection("Local"))
        let document = try await qa.openScript("SELECT 'la que no está entre las 200';\n",
                                               named: "consulta.sql", connection: connection)
        for index in 0..<200 {
            var filler = result(connection, sql: "SELECT relleno\(index)")
            filler.statement = index + 1
            document.sqlExecution.results.append(filler)
        }
        XCTAssertEqual(document.sqlExecution.results.count, 200)
        qa.controller.executeSQL()
        await qa.assertEvent("sql.execute.rejected", ["stage": "budget"])
        let error = try XCTUnwrap(document.sqlExecution.error)
        XCTAssertTrue(error.contains("Cerrá algunas pestañas"), error)
    }
}
