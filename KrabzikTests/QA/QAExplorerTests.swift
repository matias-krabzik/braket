@testable import Krabzik
import XCTest

/// Suite EXP del catálogo: el riel de modos, el árbol de bases y qué pasa cuando la carga
/// de estructura falla.
///
/// Un fallo de estructura no es un detalle: la grilla **no deja editar** sin estructura
/// (ver `SQLResultDraft.readOnlyReason`), así que el mensaje tiene que llegar a los dos
/// lugares donde el usuario está mirando: la tarjeta de la conexión y el pie del
/// resultado.
@MainActor
final class QAExplorerTests: XCTestCase {
    /// Un perfil que falla rápido: nadie escucha en el puerto 1 de loopback.
    private func refusedConnection(_ name: String = "Sin servidor") -> DatabaseConnection {
        var connection = QAFixtures.connection(name)
        connection.host = "127.0.0.1"
        connection.port = 1
        connection.connectTimeoutSeconds = 3
        return connection
    }

    /// EXP-01
    func testSwitchingBetweenTheFileAndDatabaseExplorers() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Bases", folders: ["app"])
        await qa.openProject(url)
        await qa.mount()
        await qa.assertScreen("explorer.files")
        await qa.assertControl("explorer.mode.databases", title: "Bases de datos", enabled: true)
        await qa.assertControl("explorer.mode.files", title: "Archivos", enabled: true)

        try await qa.tap("explorer.mode.databases")
        await qa.assertEvent("state.explorer", ["mode": "databases", "sidebar": "true"])
        await qa.assertScreen("explorer.databases")
        await qa.assertScreen("explorer.files", present: false)

        try await qa.tap("explorer.mode.files")
        await qa.assertEvent("state.explorer", ["mode": "files"])
        await qa.assertScreen("explorer.files")
        await qa.assertScreen("explorer.databases", present: false)
    }

    /// EXP-04
    func testASchemaFailureShowsUpOnTheCardAndNextToTheResult() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Bases")
        await qa.openProject(url)
        let profile = try await qa.addConnection(refusedConnection())
        await qa.mount()
        try await qa.tap("explorer.mode.databases")

        let store = qa.controller.database.schema
        await store.discover(profile, client: qa.controller.database.client)
        await qa.assertEvent("schema.discover.end")
        let message = try XCTUnwrap(store.errors[profile.id], "la carga tenía que fallar")
        await qa.assertControl("explorer.schema.error." + profile.name, title: message)
        await qa.assertControl("explorer.schema.retry." + profile.name, title: "Reintentar carga", enabled: true)
        XCTAssertFalse(message.lowercased().contains("password"), message)

        // El mismo mensaje tiene que estar junto al resultado, que es donde se ve por qué
        // la grilla quedó en solo lectura.
        let document = try await qa.openScript("SELECT 1;\n", connection: profile)
        var result = QAFixtures.result(profile, columns: ["id"], rows: [["1"]], sql: "SELECT 1")
        result.origins = []
        XCTAssertTrue(document.sqlExecution.begin(result))
        document.sqlExecution.receive(result)
        qa.controller.database.resultsVisible = true
        await qa.assertControl("sql.result.schemaError", title: message)
    }

    /// EXP-02 · necesita el MySQL desechable
    func testTheExplorerListsDatabasesTablesAndColumns() async throws {
        let port = try QAFixtures.mysqlPort()
        let qa = try QAHarness(self)
        var connection = QAFixtures.connection("QA real")
        connection.port = port
        connection.database = "krabzik_qa"
        let profile = try await qa.addConnection(connection)
        let client = qa.controller.database.client
        _ = try await client.execute("""
        DROP TABLE IF EXISTS braket_qa_explorer;
        CREATE TABLE braket_qa_explorer(id INT PRIMARY KEY AUTO_INCREMENT, nombre VARCHAR(40) NULL) ENGINE=InnoDB;
        """, startingLine: 1, configuration: profile, password: "", operation: UUID(),
                                     timeoutSeconds: 15, pageIndex: 0, onStatement: { _ in }, onResult: { _ in })

        let store = qa.controller.database.schema
        var preference = store.preference(profile)
        preference.visible = ["krabzik_qa"]
        store.save(preference, for: profile)
        await store.discover(profile, client: client)
        XCTAssertNil(store.errors[profile.id], store.errors[profile.id] ?? "")
        await qa.assertEvent("schema.discover.end")

        let snapshot = try XCTUnwrap(store.snapshot(profile), "tiene que quedar una estructura cargada")
        XCTAssertTrue(snapshot.databases.contains("krabzik_qa"), snapshot.databases.joined(separator: ", "))
        let table = try XCTUnwrap(snapshot.tables.first { $0.name == "braket_qa_explorer" })
        XCTAssertEqual(table.database, "krabzik_qa")
        XCTAssertEqual(table.columns.map(\.name), ["id", "nombre"])
        XCTAssertTrue(table.uniqueKeys.contains { $0 == ["id"] }, "la clave se marca en el árbol")
        await client.closeAll()
        await client.shutdown()
    }

    /// SQL-21
    func testOpeningATableQueryFromTheExplorer() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Bases")
        await qa.openProject(url)
        let profile = try await qa.addConnection(QAFixtures.connection("Local"))
        let table = QAFixtures.table()

        qa.controller.openTableQuery(table, connection: profile)
        await qa.assertEvent("table.query.ok", ["table": table.qualified, "connection": "Local"])
        let document = try XCTUnwrap(qa.controller.selectedDocument)
        XCTAssertTrue(document.isDraft, "se abre un borrador, no un archivo en disco")
        XCTAssertEqual(document.text, "SELECT * FROM \(table.qualified);\n")
        XCTAssertEqual(document.language, "SQL")
        XCTAssertEqual(qa.controller.connections.selected(for: document)?.id, profile.id,
                       "el borrador queda con la conexión del árbol")
        await qa.assertEvent("sql.execute.request", ["connection": "Local"])
    }
}
