import AppKit
@testable import Krabzik
import XCTest

/// Suite GRI del catálogo: la grilla de resultados.
///
/// Es el caso que da nombre a todo esto: si la interfaz ofrece editar, lo que se edita
/// tiene que quedar en modo edición, aceptar un cambio y poder guardarse. Y, al revés,
/// cuando no se puede editar hay que decir **por qué**: cada motivo de solo lectura es un
/// caso del catálogo, porque cada uno protege algo distinto.
@MainActor
final class QAGridEditingTests: XCTestCase {
    /// GRI-01
    func testAComputedResultIsReadOnlyWithAReason() async throws {
        let qa = try QAHarness(self)
        let connection = QAFixtures.connection()
        var result = QAFixtures.result(connection, columns: ["suma"], rows: [["2"]], sql: "SELECT 1+1 AS suma")
        result.origins = [SQLColumnOrigin(database: "", table: "", column: "")]
        let draft = QAFixtures.draft(connection, result: result)
        XCTAssertFalse(draft.canEdit)
        XCTAssertEqual(draft.reason, "Solo lectura: resultado calculado o sin tabla de origen.")
        await qa.assertEvent("state.draft", ["canEdit": "false"])
    }

    /// GRI-02
    func testWithoutAUniqueKeyTheGridStaysReadOnly() async throws {
        _ = try QAHarness(self)
        let connection = QAFixtures.connection()
        let draft = QAFixtures.draft(connection,
                                     result: QAFixtures.result(connection, columns: ["nombre", "estado"],
                                                               rows: [["ana", "nuevo"]]))
        XCTAssertFalse(draft.canEdit)
        XCTAssertEqual(draft.reason, "Solo lectura: incluí la clave primaria completa o, si no existe, una clave única no nullable.")
    }

    /// GRI-03
    func testJoinsAndGroupingStayReadOnly() async throws {
        _ = try QAHarness(self)
        let connection = QAFixtures.connection()
        for sql in ["SELECT id, nombre FROM personas JOIN pedidos USING (id)",
                    "SELECT id, nombre FROM personas GROUP BY id",
                    "SELECT DISTINCT id, nombre FROM personas"] {
            let draft = QAFixtures.draft(connection,
                                         result: QAFixtures.result(connection, columns: ["id", "nombre"],
                                                                   rows: [["1", "ana"]], sql: sql))
            XCTAssertFalse(draft.canEdit, sql)
            XCTAssertEqual(draft.reason, "Solo lectura: usá un SELECT de una sola tabla, con subconsultas solo en los filtros WHERE.", sql)
        }
    }

    /// GRI-04
    func testOnlyInnoDBBaseTablesAreEditable() async throws {
        _ = try QAHarness(self)
        let connection = QAFixtures.connection()
        let myisam = QAFixtures.draft(connection, table: QAFixtures.table(engine: "MyISAM"))
        XCTAssertEqual(myisam.reason, "Solo lectura: la edición transaccional requiere una tabla InnoDB.")
        let view = QAFixtures.draft(connection, table: QAFixtures.table(kind: "VIEW"))
        XCTAssertEqual(view.reason, "Solo lectura: la edición transaccional requiere una tabla InnoDB.")
        let partial = QAFixtures.draft(connection, table: QAFixtures.table(metadataComplete: false))
        XCTAssertEqual(partial.reason, "Solo lectura: falta completar la estructura de esta tabla.")
        let missing = SQLResultDraft(result: QAFixtures.result(connection))
        missing.configure(nil)
        XCTAssertEqual(missing.reason,
                       "Solo lectura: estructura no disponible. Actualizá las bases de la conexión.")
    }

    /// GRI-05
    func testTheProfilePolicyOverridesEverythingElse() async throws {
        _ = try QAHarness(self)
        let connection = QAFixtures.connection("Producción", policy: .readOnly)
        let draft = QAFixtures.draft(connection)
        XCTAssertFalse(draft.canEdit)
        XCTAssertEqual(draft.reason, "Solo lectura: el perfil «Producción» no permite escrituras.")
    }

    /// GRI-06
    func testEnteringACellPutsItInEditMode() async throws {
        let qa = try QAHarness(self)
        let draft = QAFixtures.draft(QAFixtures.connection())
        XCTAssertTrue(draft.canEdit, draft.reason)
        XCTAssertTrue(draft.canEditCell(row: 0, column: 1))
        XCTAssertTrue(draft.beginEditing(row: 0, column: 1))
        XCTAssertTrue(draft.isEditingCell, "la celda que se está editando queda en modo edición")
        XCTAssertEqual(draft.selectedCell, SQLCell(row: 0, column: 1))
        await qa.assertEvent("grid.edit.begin", ["row": "0", "column": "1", "value": "ana"])
        await qa.assertEvent("state.draft", ["editing": "true"])
    }

    /// GRI-07
    func testCommittingKeepsTheValueAndCancellingDiscardsIt() async throws {
        let qa = try QAHarness(self)
        let draft = QAFixtures.draft(QAFixtures.connection())
        XCTAssertTrue(draft.beginEditing(row: 0, column: 1))
        draft.endEditing(commit: .text("ANA"))
        XCTAssertFalse(draft.isEditingCell)
        XCTAssertEqual(draft.value(row: 0, column: 1), .text("ANA"))
        await qa.assertEvent("grid.edit.end", ["committed": "true", "value": "ANA"])

        XCTAssertTrue(draft.beginEditing(row: 1, column: 1))
        draft.endEditing()
        XCTAssertFalse(draft.isEditingCell)
        XCTAssertEqual(draft.value(row: 1, column: 1), .text("beto"), "cancelar no cambia la celda")
        await qa.assertEvent("grid.edit.end", ["committed": "false"])
    }

    /// GRI-08
    func testAChangeEnablesTheSaveButton() async throws {
        let qa = try QAHarness(self)
        let draft = QAFixtures.draft(QAFixtures.connection())
        XCTAssertFalse(draft.hasChanges)
        draft.beginEditing(row: 0, column: 1)
        draft.endEditing(commit: .text("ANA"))
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.changes.count, 1)
        await qa.assertEvent("state.draft", ["hasChanges": "true", "changes": "1", "editing": "false"])
        draft.beginEditing(row: 0, column: 1)
        draft.endEditing(commit: .text("ana"))
        XCTAssertFalse(draft.hasChanges, "volver al valor original deja de ser un cambio")
    }

    /// GRI-09
    func testSavingIsDisabledWhileACellIsBeingEdited() async throws {
        _ = try QAHarness(self)
        let draft = QAFixtures.draft(QAFixtures.connection())
        draft.beginEditing(row: 0, column: 1)
        draft.endEditing(commit: .text("ANA"))
        XCTAssertTrue(draft.canEdit && draft.hasChanges && !draft.isEditingCell,
                      "con un cambio y sin editar, Guardar cambios está habilitado")
        draft.beginEditing(row: 1, column: 1)
        XCTAssertTrue(draft.isEditingCell, "mientras se edita, Guardar cambios queda deshabilitado")
        XCTAssertFalse(draft.canDeleteSelected, "tampoco se borra una fila mientras se edita")
        XCTAssertFalse(draft.canResetSelected)
    }

    /// GRI-10
    func testAddingARowNeedsEveryColumnCoveredOrDefaulted() async throws {
        let qa = try QAHarness(self)
        let connection = QAFixtures.connection()
        let partial = QAFixtures.draft(connection)
        XCTAssertFalse(partial.canInsert, "falta «obligatoria», que es NOT NULL y sin DEFAULT")
        partial.addRow()
        await qa.assertEvent("grid.addRow.denied")
        XCTAssertEqual(partial.rowCount, 2)

        let complete = QAFixtures.draft(connection,
                                        result: QAFixtures.result(connection,
                                                                  columns: ["id", "nombre", "estado", "obligatoria"],
                                                                  rows: [["1", "ana", "nuevo", "7"]]))
        XCTAssertTrue(complete.canInsert)
        complete.addRow()
        XCTAssertEqual(complete.rowCount, 2)
        XCTAssertEqual(complete.selectedCell, SQLCell(row: 1, column: 0))
        XCTAssertEqual(complete.value(row: 1, column: 0), .serverDefault, "el auto_increment lo pone el servidor")
    }

    /// GRI-11
    func testDeletingARowTogglesItsMark() async throws {
        let qa = try QAHarness(self)
        let draft = QAFixtures.draft(QAFixtures.connection())
        draft.selectedCell = SQLCell(row: 0, column: 0)
        XCTAssertTrue(draft.canDeleteSelected)
        draft.deleteRow(0)
        XCTAssertEqual(draft.deleted, [0])
        XCTAssertTrue(draft.hasChanges)
        await qa.assertEvent("grid.deleteRow", ["row": "0"])
        draft.deleteRow(0)
        XCTAssertTrue(draft.deleted.isEmpty, "volver a pedirlo desmarca la fila")
        XCTAssertFalse(draft.hasChanges)
    }

    /// GRI-12
    func testResettingACellRestoresTheOriginalValue() async throws {
        let qa = try QAHarness(self)
        let draft = QAFixtures.draft(QAFixtures.connection())
        draft.beginEditing(row: 0, column: 1)
        draft.endEditing(commit: .text("ANA"))
        XCTAssertTrue(draft.canResetSelected)
        draft.resetSelected()
        XCTAssertEqual(draft.value(row: 0, column: 1), .text("ana"))
        XCTAssertFalse(draft.canResetSelected, "sin cambio, Restablecer queda deshabilitado")
        await qa.assertEvent("grid.reset")
    }

    /// GRI-13
    func testTheReviewSheetShowsTheExactTransaction() async throws {
        _ = try QAHarness(self)
        let connection = QAFixtures.connection()
        let draft = QAFixtures.draft(connection,
                                     result: QAFixtures.result(connection,
                                                               columns: ["id", "nombre", "estado", "obligatoria"],
                                                               rows: [["1", "ana", "nuevo", "7"],
                                                                      ["2", "beto", "listo", "8"]]))
        draft.beginEditing(row: 0, column: 1)
        draft.endEditing(commit: .text("ANA"))
        draft.deleteRow(1)
        draft.addRow()
        let mutations = try draft.mutations()
        XCTAssertEqual(mutations.count, 3)
        let sql = mutations.map(\.sql).joined(separator: "\n")
        XCTAssertTrue(sql.contains("UPDATE `qa`.`personas` SET `nombre` = "), sql)
        XCTAssertTrue(sql.contains("DELETE FROM `qa`.`personas` WHERE"), sql)
        XCTAssertTrue(sql.contains("INSERT INTO `qa`.`personas`"), sql)
        XCTAssertTrue(sql.contains("LIMIT 1"), "cada mutación toca una sola fila")
        let verifications = mutations.compactMap(\.verificationSQL).joined(separator: "\n")
        XCTAssertTrue(verifications.contains("FOR UPDATE"), "la verificación bloquea la fila: " + verifications)
        XCTAssertTrue(sql.contains("`nombre` = 'ANA'"), "los valores se muestran como literales SQL legibles")
        XCTAssertFalse(sql.contains("CONVERT("))
    }

    /// GRI-14
    func testNullAndDefaultAreRefusedWhereTheyDoNotApply() async throws {
        let qa = try QAHarness(self)
        let connection = QAFixtures.connection()
        let draft = QAFixtures.draft(connection,
                                     result: QAFixtures.result(connection,
                                                               columns: ["id", "nombre", "estado", "obligatoria"],
                                                               rows: [["1", "ana", "nuevo", "7"]]))
        draft.set(.null, row: 0, column: 2)
        XCTAssertEqual(draft.value(row: 0, column: 2), .text("nuevo"), "«estado» es NOT NULL")
        await qa.assertEvent("grid.set.denied", ["reason": "la columna no admite NULL"])
        draft.set(.serverDefault, row: 0, column: 3)
        XCTAssertEqual(draft.value(row: 0, column: 3), .text("7"), "«obligatoria» no tiene DEFAULT")
        await qa.assertEvent("grid.set.denied", ["reason": "la columna no tiene DEFAULT"])
        draft.set(.null, row: 0, column: 1)
        XCTAssertEqual(draft.value(row: 0, column: 1), .null, "«nombre» admite NULL")
        draft.set(.serverDefault, row: 0, column: 2)
        XCTAssertEqual(draft.value(row: 0, column: 2), .serverDefault, "«estado» tiene DEFAULT")
    }

    /// GRI-15
    func testGeneratedColumnsCannotBeEdited() async throws {
        let qa = try QAHarness(self)
        let draft = QAFixtures.draft(QAFixtures.connection())
        XCTAssertFalse(draft.canEditCell(row: 0, column: 3), "«calculado» es GENERATED")
        XCTAssertFalse(draft.beginEditing(row: 0, column: 3))
        XCTAssertFalse(draft.isEditingCell)
        await qa.assertEvent("grid.edit.denied", ["column": "3"])
        draft.set(.text("99"), row: 0, column: 3)
        XCTAssertEqual(draft.value(row: 0, column: 3), .text("10"))
    }

    /// GRI-19
    func testCancellingTheReviewKeepsThePendingChanges() async throws {
        _ = try QAHarness(self)
        let draft = QAFixtures.draft(QAFixtures.connection())
        draft.beginEditing(row: 0, column: 1)
        draft.endEditing(commit: .text("ANA"))
        draft.showingReview = true
        draft.showingReview = false
        XCTAssertTrue(draft.hasChanges, "cancelar la revisión no descarta nada")
        XCTAssertEqual(draft.changes.count, 1)
    }

    /// GRI-16, GRI-17 · necesita el MySQL desechable
    func testSubmittingAppliesTheChangesInOneTransaction() async throws {
        let port = try QAFixtures.mysqlPort()
        let qa = try QAHarness(self)
        var connection = QAFixtures.connection("QA real")
        connection.port = port
        connection.database = "krabzik_qa"
        let client = qa.controller.database.client
        let profile = try await qa.addConnection(connection)
        _ = try await client.execute("""
        DROP TABLE IF EXISTS braket_qa_grid;
        CREATE TABLE braket_qa_grid(id INT PRIMARY KEY AUTO_INCREMENT, nombre VARCHAR(80) NULL) ENGINE=InnoDB;
        INSERT INTO braket_qa_grid(nombre) VALUES ('uno'),('dos');
        """, startingLine: 1, configuration: profile, password: "", operation: UUID(),
                                     timeoutSeconds: 15, pageIndex: 0, onStatement: { _ in }, onResult: { _ in })
        let snapshot = try await client.schema(profile, password: "", databases: ["krabzik_qa"])
        let table = try XCTUnwrap(snapshot.tables.first { $0.name == "braket_qa_grid" })

        var result = SQLResult(statement: 1, line: 1)
        result.sql = "SELECT id, nombre FROM braket_qa_grid ORDER BY id"
        result.connection = profile
        result.database = "krabzik_qa"
        result.columns = ["id", "nombre"]
        result.origins = ["id", "nombre"].map { SQLColumnOrigin(database: "krabzik_qa", table: "braket_qa_grid", column: $0) }
        result.rows = [["1", "uno"], ["2", "dos"]]
        let draft = SQLResultDraft(result: result)
        draft.configure(table)
        XCTAssertTrue(draft.canEdit, draft.reason)
        draft.beginEditing(row: 0, column: 1)
        draft.endEditing(commit: .text("UNO"))
        qa.controller.database.submit(draft, profiles: qa.controller.connections.profiles)
        await qa.settle(until: { draft.sent || draft.error != nil }, timeout: 10)
        XCTAssertNil(draft.error, draft.error ?? "")
        await qa.assertEvent("grid.submit.ok")
        XCTAssertTrue(draft.sent)
        XCTAssertFalse(draft.canEdit, "después de enviar, la grilla queda en solo lectura")
        XCTAssertTrue(draft.reason.contains("Volvé a ejecutar"), draft.reason)
        await client.closeAll()
        await client.shutdown()
    }

    /// GRI-20
    func testColumnWidthsAreKeptPerResult() async throws {
        let qa = try QAHarness(self)
        let connection = QAFixtures.connection()
        let first = QAFixtures.draft(connection, result: QAFixtures.result(connection, sql: "SELECT uno"))
        let second = QAFixtures.draft(connection, result: QAFixtures.result(connection, sql: "SELECT dos"))

        // La grilla de verdad: al soltar el borde de la columna, AppKit avisa al
        // coordinador y el ancho queda en el borrador de **ese** resultado.
        let coordinator = SQLResultGrid.Coordinator(draft: first)
        let table = SQLGridTable()
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.delegate = coordinator
        table.dataSource = coordinator
        coordinator.table = table
        for (index, name) in first.result.columns.enumerated() {
            let column = NSTableColumn(identifier: .init("\(index)"))
            column.title = name
            column.minWidth = 44
            column.maxWidth = 4000
            column.resizingMask = .userResizingMask
            table.addTableColumn(column)
        }

        table.tableColumns[1].width = 210
        await qa.assertEvent("grid.column.resize", ["column": "1", "width": "210"])
        XCTAssertEqual(first.widths[1] ?? 0, 210, accuracy: 0.5)
        XCTAssertTrue(second.widths.isEmpty, "el otro resultado conserva sus propios anchos")

        // Volver a leer la estructura no pierde el ancho elegido.
        first.configure(QAFixtures.table())
        XCTAssertEqual(first.widths[1] ?? 0, 210, accuracy: 0.5)
    }

    /// GRI-18 · necesita el MySQL desechable
    func testARowChangedOnTheServerRollsEverythingBack() async throws {
        let port = try QAFixtures.mysqlPort()
        let qa = try QAHarness(self)
        var connection = QAFixtures.connection("QA real")
        connection.port = port
        connection.database = "krabzik_qa"
        let client = qa.controller.database.client
        let profile = try await qa.addConnection(connection)
        func run(_ sql: String) async throws {
            _ = try await client.execute(sql, startingLine: 1, configuration: profile, password: "",
                                         operation: UUID(), timeoutSeconds: 15, pageIndex: 0,
                                         onStatement: { _ in }, onResult: { _ in })
        }
        try await run("""
        DROP TABLE IF EXISTS braket_qa_conflict;
        CREATE TABLE braket_qa_conflict(id INT PRIMARY KEY AUTO_INCREMENT, nombre VARCHAR(80) NULL) ENGINE=InnoDB;
        INSERT INTO braket_qa_conflict(nombre) VALUES ('uno'),('dos');
        """)
        let snapshot = try await client.schema(profile, password: "", databases: ["krabzik_qa"])
        let table = try XCTUnwrap(snapshot.tables.first { $0.name == "braket_qa_conflict" })

        var result = SQLResult(statement: 1, line: 1)
        result.sql = "SELECT id, nombre FROM braket_qa_conflict ORDER BY id"
        result.connection = profile
        result.database = "krabzik_qa"
        result.columns = ["id", "nombre"]
        result.origins = ["id", "nombre"].map { SQLColumnOrigin(database: "krabzik_qa", table: "braket_qa_conflict",
                                                                column: $0) }
        result.rows = [["1", "uno"], ["2", "dos"]]
        let draft = SQLResultDraft(result: result)
        draft.configure(table)
        XCTAssertTrue(draft.canEdit, draft.reason)
        draft.beginEditing(row: 0, column: 1)
        draft.endEditing(commit: .text("UNO"))
        draft.beginEditing(row: 1, column: 1)
        draft.endEditing(commit: .text("DOS"))
        XCTAssertEqual(draft.changes.count, 2)

        // Alguien cambió la fila por fuera después de que se leyó el resultado.
        try await run("UPDATE braket_qa_conflict SET nombre = 'otro' WHERE id = 1;")

        qa.controller.database.submit(draft, profiles: qa.controller.connections.profiles)
        await qa.settle(until: { draft.sent || draft.error != nil }, timeout: 15)
        await qa.assertEvent("grid.submit.failed")
        XCTAssertFalse(draft.sent, "no se aplicó nada")
        XCTAssertNotNil(draft.error)
        XCTAssertEqual(draft.changes.count, 2, "los cambios siguen pendientes para revisar")

        let collector = QARowCollector()
        _ = try await client.execute("SELECT nombre FROM braket_qa_conflict ORDER BY id;", startingLine: 1,
                                     configuration: profile, password: "", operation: UUID(), timeoutSeconds: 15,
                                     pageIndex: 0, onStatement: { _ in }, onResult: { await collector.set($0.rows) })
        let rows = await collector.rows
        XCTAssertEqual(rows, [["otro"], ["dos"]], "la transacción se revirtió completa")
        await client.closeAll()
        await client.shutdown()
    }
}

/// Junta las filas que llegan del cliente, que entrega los resultados desde fuera del
/// main actor.
private actor QARowCollector {
    var rows: [[String?]] = []
    func set(_ value: [[String?]]) { rows = value }
}
