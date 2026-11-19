import AppKit
@testable import Krabzik
import XCTest

/// Suite SQL del catálogo: qué se manda, cuándo, y qué se rechaza antes de mandarlo.
///
/// La guarda de escritura (S8) es el centro: un perfil en solo lectura tiene que
/// rechazar **sin abrir la conexión**, y uno en «confirmar» tiene que preguntar una vez
/// por ejecución diciendo a dónde va.
@MainActor
final class QASQLExecutionTests: XCTestCase {
    private func script(_ qa: QAHarness, _ text: String, connection: DatabaseConnection?) async throws -> EditorDocument {
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        if let connection { try qa.controller.connections.addShared(connection) }
        return try await qa.openScript(text, named: "consulta.sql", connection: connection)
    }

    /// SQL-01
    func testWithoutAConnectionTheRunButtonIsDisabled() async throws {
        let qa = try QAHarness(self)
        await qa.mount()
        let document = try await script(qa, "SELECT 1;\n", connection: nil)
        XCTAssertNil(qa.controller.connections.selected(for: document))
        await qa.settle(until: { qa.control("sql.toolbar.execute") != nil })
        await qa.assertControl("sql.toolbar.execute", title: "Ejecutar", enabled: false)
        qa.controller.executeSQL()
        await qa.assertEvent("sql.execute.unavailable", ["connection": "false"])
        qa.assertNoEvent("sql.execute.begin")
    }

    /// SQL-02
    func testEachScriptKeepsItsOwnConnection() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        let one = try await qa.addConnection(QAFixtures.connection("Desarrollo"))
        let two = try await qa.addConnection(QAFixtures.connection("Reportes"))
        let first = try await qa.openScript("SELECT 1;\n", named: "uno.sql", connection: one)
        let second = try await qa.openScript("SELECT 2;\n", named: "dos.sql", connection: two)
        XCTAssertEqual(qa.controller.connections.selected(for: first)?.name, "Desarrollo")
        XCTAssertEqual(qa.controller.connections.selected(for: second)?.name, "Reportes")
        await qa.assertEvent("connection.select", ["connection": "Reportes"])

        _ = await qa.controller.files.close(first)
        let reopened = try await qa.openScript("SELECT 1;\n", named: "uno.sql")
        XCTAssertEqual(qa.controller.connections.selected(for: reopened)?.name, "Desarrollo",
                       "la selección es del archivo y sobrevive a cerrarlo")
    }

    /// SQL-03
    func testRunningSendsOnlyTheStatementUnderTheCursor() async throws {
        let qa = try QAHarness(self)
        let connection = try await qa.addConnection(QAFixtures.connection("Local"))
        let text = "SELECT 1;\nSELECT 2;\nSELECT 3;\n"
        let document = try await script(qa, text, connection: connection)
        let range = (text as NSString).range(of: "SELECT 2")
        document.selectedRange = NSRange(location: range.location + 2, length: 0)
        qa.controller.executeSQL()
        await qa.assertEvent("sql.execute.begin", ["sql": "SELECT 2", "line": "2"])
        qa.controller.database.cancel(document.sqlExecution)
        await qa.controller.database.client.shutdown()
    }

    /// SQL-04
    func testAnEmptyLineUnderTheCursorExplainsItself() async throws {
        let qa = try QAHarness(self)
        let connection = try await qa.addConnection(QAFixtures.connection("Local"))
        let text = "SELECT 1;\n\nSELECT 3;\n"
        let document = try await script(qa, text, connection: connection)
        document.selectedRange = NSRange(location: (text as NSString).range(of: "\n\n").location + 1, length: 0)
        qa.controller.executeSQL()
        await qa.assertEvent("sql.execute.rejected", ["stage": "empty"])
        XCTAssertEqual(document.sqlExecution.error, "No hay una sentencia SQL bajo el cursor.")
        qa.assertNoEvent("sql.execute.begin")
    }

    /// SQL-10
    func testTheTimeoutIsClampedToItsRange() async throws {
        let qa = try QAHarness(self)
        let connection = try await qa.addConnection(QAFixtures.connection("Local"))
        let document = try await script(qa, "SELECT 1;\n", connection: connection)
        XCTAssertEqual(document.sqlExecution.timeoutSeconds, 60, "el valor por defecto")
        document.sqlExecution.timeoutSeconds = 0
        qa.controller.executeSQL()
        await qa.assertEvent("sql.execute.begin", ["timeout": "1"])
        qa.controller.database.cancel(document.sqlExecution)
        await qa.settle(until: { !document.sqlExecution.isRunning }, timeout: 10)
        document.sqlExecution.timeoutSeconds = 9999
        qa.controller.executeSQL()
        await qa.assertEvent("sql.execute.begin", ["timeout": "3600"])
        qa.controller.database.cancel(document.sqlExecution)
        await qa.controller.database.client.shutdown()
    }

    /// SQL-12, CON-14
    func testAReadOnlyProfileRejectsWritesWithoutConnecting() async throws {
        let qa = try QAHarness(self)
        let connection = try await qa.addConnection(QAFixtures.connection("Producción", policy: .readOnly))
        let document = try await script(qa, "DELETE FROM personas WHERE id = 1;\n", connection: connection)
        qa.controller.executeSQL()
        await qa.assertEvent("sql.writeGuard.writes", ["policy": "readOnly", "writes": "1", "total": "1"])
        await qa.assertEvent("sql.writeGuard.rejected")
        qa.assertNoEvent("sql.execute.begin")
        qa.assertNoEvent("connection.connect.request")
        XCTAssertEqual(qa.controller.database.state(connection.id).status, .disconnected)
        let error = try XCTUnwrap(document.sqlExecution.error)
        XCTAssertTrue(error.contains("solo lectura"), error)
        XCTAssertTrue(error.contains("No se abrió ninguna conexión"), error)
        XCTAssertNotNil(connection.effectiveWritePolicy.badge, "la insignia del perfil tiene que verse")
    }

    /// SQL-13
    func testTheConfirmPolicyAsksOncePerExecution() async throws {
        let qa = try QAHarness(self)
        let connection = try await qa.addConnection(QAFixtures.connection("Staging", policy: .confirm))
        let text = "UPDATE personas SET nombre = 'x' WHERE id = 1;\nDELETE FROM personas WHERE id = 2;\n"
        let document = try await script(qa, text, connection: connection)
        document.selectedRange = NSRange(location: 0, length: (text as NSString).length)
        qa.script.confirmWrites = true
        qa.controller.executeSQL()
        await qa.assertEvent("sql.writeGuard.writes", ["policy": "confirm", "writes": "2", "total": "2"])
        await qa.assertEvent("dialog.sql.confirmWrites", ["answer": "run", "connection": "Staging", "writes": "2"])
        XCTAssertEqual(qa.events("dialog.sql.confirmWrites").count, 1, "se pregunta una sola vez por ejecución")
        qa.controller.database.cancel(document.sqlExecution)
        await qa.controller.database.client.shutdown()
    }

    /// SQL-14
    func testCancellingTheWriteGuardRunsNothing() async throws {
        let qa = try QAHarness(self)
        let connection = try await qa.addConnection(QAFixtures.connection("Staging", policy: .confirm))
        let document = try await script(qa, "DELETE FROM personas WHERE id = 1;\n", connection: connection)
        qa.script.confirmWrites = false
        qa.controller.executeSQL()
        await qa.assertEvent("dialog.sql.confirmWrites", ["answer": "cancel"])
        qa.assertNoEvent("sql.execute.begin")
        XCTAssertFalse(document.sqlExecution.isRunning)
        XCTAssertNil(document.sqlExecution.error, "cancelar no necesita explicación")
    }

    /// SQL-15
    func testTheUnrestrictedPolicyNeverAsks() async throws {
        let qa = try QAHarness(self)
        let connection = try await qa.addConnection(QAFixtures.connection("Local"))
        XCTAssertEqual(connection.effectiveWritePolicy, .unrestricted)
        let document = try await script(qa, "DELETE FROM personas WHERE id = 1;\n", connection: connection)
        qa.controller.executeSQL()
        qa.assertNoEvent("dialog.sql.confirmWrites")
        qa.assertNoEvent("sql.writeGuard.writes")
        await qa.assertEvent("sql.execute.begin")
        qa.controller.database.cancel(document.sqlExecution)
        await qa.controller.database.client.shutdown()
    }

    /// SQL-16
    func testCommentsStringsAndDelimitersDoNotSplitStatements() async throws {
        _ = try QAHarness(self)
        var cursor = SQLScript("""
        -- un ; en un comentario
        SELECT 'a;b', "c;d", `a;b`;
        DELIMITER $$
        CREATE PROCEDURE p()
        BEGIN
          SELECT 'comilla '' ; adentro';
          SELECT 2;
        END$$
        DELIMITER ;
        /* otro ; */ SELECT 3;
        """)
        var statements: [SQLStatement] = []
        while let statement = try cursor.next() { statements.append(statement) }
        XCTAssertEqual(statements.count, 3)
        XCTAssertEqual(statements[0].line, 2)
        XCTAssertTrue(statements[1].text.contains("SELECT 2;"))
        XCTAssertTrue(statements[2].text.hasSuffix("SELECT 3"))
    }

    /// SQL-19
    func testSelectingAnotherDatabaseIsRequested() async throws {
        let qa = try QAHarness(self)
        var connection = QAFixtures.connection("Local")
        connection.port = 9
        connection.connectTimeoutSeconds = 1
        let profile = try await qa.addConnection(connection)
        qa.controller.database.selectDatabase("reportes", connection: profile)
        await qa.assertEvent("connection.useDatabase.request", ["database": "reportes", "name": "Local"])
        await qa.settle(until: { !qa.controller.database.state(profile.id).busy }, timeout: 10)
        await qa.assertEvent("connection.useDatabase.failed")
        XCTAssertNotNil(qa.controller.database.state(profile.id).error)
        await qa.controller.database.client.shutdown()
    }

    /// SQL-11 · necesita el MySQL desechable
    func testCancellingAQueryIsRequestedAndReported() async throws {
        let port = try QAFixtures.mysqlPort()
        let qa = try QAHarness(self)
        var connection = QAFixtures.connection("QA real")
        connection.port = port
        connection.database = "krabzik_qa"
        let profile = try await qa.addConnection(connection)
        let document = try await script(qa, "SELECT SLEEP(20);\n", connection: profile)
        qa.controller.executeSQL()
        await qa.settle(until: { document.sqlExecution.isRunning }, timeout: 10)
        qa.controller.database.cancel(document.sqlExecution)
        await qa.assertEvent("sql.cancel.request")
        await qa.settle(until: { !document.sqlExecution.isRunning }, timeout: 20)
        XCTAssertFalse(document.sqlExecution.isRunning)
        await qa.controller.database.client.shutdown()
    }

    /// SQL-20
    func testCompletionOffersSchemaNamesAndKeepsTheAlias() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Bases")
        await qa.openProject(url)
        let profile = try await qa.addConnection(QAFixtures.connection("Local"))
        let store = qa.controller.database.schema
        store.snapshots[profile.id] = SQLSchemaSnapshot(connection: profile, databases: [QAFixtures.database],
                                                        tables: [QAFixtures.table()])
        XCTAssertNotNil(store.snapshot(profile))

        let text = "SELECT p.nom FROM personas p"
        let names = store.completions(connection: profile, database: QAFixtures.database,
                                      text: text, position: 12)
        XCTAssertEqual(names, ["nombre"], "con el alias resuelto, solo ofrece columnas de esa tabla")
        XCTAssertTrue(store.completions(connection: profile, database: QAFixtures.database,
                                        text: "SELECT per", position: 10).contains("personas"),
                      "sin calificador ofrece también las tablas")

        // El editor de verdad: pedir la sugerencia y aceptarla con Enter tiene que
        // reemplazar **solo la columna** y dejar el alias donde estaba.
        let document = try await qa.openScript(text, named: "consulta.sql", connection: profile)
        let surface = EditorSurface(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        surface.completion = { [weak store] value, position in
            store?.completions(connection: profile, database: QAFixtures.database,
                               text: value, position: position) ?? []
        }
        surface.textView.sqlCompletionEnabled = true
        surface.textView.setSelectedRange(NSRange(location: 12, length: 0))
        surface.layoutSubtreeIfNeeded()
        surface.textView.complete(nil)
        await qa.assertEvent("editor.completion.show", ["count": "1", "first": "nombre"])

        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: "\r", charactersIgnoringModifiers: "\r",
                                                   isARepeat: false, keyCode: 36))
        XCTAssertTrue(surface.textView.completionKey?(enter) == true, "Enter acepta la sugerencia")
        await qa.assertEvent("editor.completion.accept", ["value": "nombre", "replaced": "nom"])
        XCTAssertEqual(surface.textView.string, "SELECT p.nombre FROM personas p")
        window.contentView = nil
    }
}
