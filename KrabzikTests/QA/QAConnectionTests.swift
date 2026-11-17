@testable import Krabzik
import XCTest

/// Suite CON del catálogo: el catálogo de conexiones y la hoja de conexión.
///
/// Lo que se protege acá: un perfil mal formado no entra al catálogo, cambiar el extremo
/// no hereda la contraseña, y un proyecto ajeno no puede modificar lo que ya estaba
/// guardado.
@MainActor
final class QAConnectionTests: XCTestCase {
    /// CON-01, CON-02
    func testTheEmptyCatalogOffersANewConnection() async throws {
        let qa = try QAHarness(self)
        await qa.mount()
        qa.controller.database.showingConnections = true
        await qa.assertScreen("connections")
        await qa.assertControl("connections.new", title: "Nueva conexión", enabled: true)
        XCTAssertTrue(qa.controller.connections.profiles.isEmpty)

        try await qa.tap("connections.new")
        await qa.assertScreen("connection.sheet")
        await qa.assertControl("connection.sheet.test", title: "Probar", enabled: true)
        await qa.assertControl("connection.sheet.save", title: "Guardar", enabled: true)
        await qa.assertControl("connection.sheet.cancel", title: "Cancelar", enabled: true)
    }

    /// CON-03
    func testSavingValidatesTheProfileBeforeTouchingTheCatalog() async throws {
        let qa = try QAHarness(self)
        var invalid = QAFixtures.connection("")
        await assertRejected(qa, invalid, "un perfil sin nombre")
        invalid = QAFixtures.connection()
        invalid.port = 0
        await assertRejected(qa, invalid, "puerto fuera de rango")
        invalid = QAFixtures.connection()
        invalid.connectTimeoutSeconds = 301
        await assertRejected(qa, invalid, "timeout de más de 300 s")
        invalid = QAFixtures.connection()
        invalid.host = ""
        await assertRejected(qa, invalid, "sin servidor")
        XCTAssertTrue(qa.controller.connections.profiles.isEmpty, "ningún rechazo toca el catálogo")
    }

    /// CON-04
    func testAdvancedTLSParametersAreValidatedAndNormalized() async throws {
        let qa = try QAHarness(self)
        var certificateOnly = QAFixtures.connection()
        certificateOnly.tlsClientCertificatePath = "/tmp/cliente.pem"
        await assertRejected(qa, certificateOnly, "certificado cliente sin su clave")

        var spaced = QAFixtures.connection("Con SNI")
        spaced.tlsClientCertificatePath = "/tmp/cliente.pem"
        spaced.tlsClientKeyPath = "/tmp/cliente-key.pem"
        spaced.tlsServerName = "  db.example.com  "
        let saved = try await qa.addConnection(spaced)
        XCTAssertEqual(saved.tlsServerName, "db.example.com")
    }

    /// CON-17
    func testAFailedTestOffersTheDiagnosticsExportWithoutSecrets() async throws {
        let qa = try QAHarness(self)
        await qa.mount()
        qa.controller.database.showingConnections = true
        await qa.assertScreen("connections")
        try await qa.tap("connections.new")
        await qa.assertScreen("connection.sheet")
        qa.assertNoControl("connection.sheet.diagnostics")

        // La hoja arranca con un perfil sin nombre: «Probar» falla sin tocar la red.
        try await qa.tap("connection.sheet.test")
        await qa.assertEvent("connection.test.failed")
        let message = try XCTUnwrap(qa.event("connection.test.failed")?.fields["message"])
        await qa.assertControl("connection.sheet.message", title: message)
        await qa.assertControl("connection.sheet.diagnostics", title: "Exportar diagnóstico MySQL…", enabled: true)

        // Y lo que se exportaría no lleva contraseña ni destino.
        let diagnostics = MySQLDiagnostics(directory: qa.root.appendingPathComponent("logs", isDirectory: true))
        var profile = QAFixtures.connection("Producción")
        profile.host = "db.interno.example"
        profile.username = "cuenta_de_la_app"
        await diagnostics.record(.failed, attempt: UUID(), configuration: profile,
                                 error: DatabaseFailure("no se pudo conectar"))
        let text = String(decoding: try await diagnostics.snapshot(), as: UTF8.self)
        XCTAssertTrue(text.contains("connection.failed"), text)
        for secret in ["Krabzik QA ephemeral", "db.interno.example", "cuenta_de_la_app", "no se pudo conectar"] {
            XCTAssertFalse(text.contains(secret), "el diagnóstico no puede nombrar «\(secret)»:\n" + text)
        }
    }

    /// CON-05
    func testASavedProfileSurvivesAProjectChange() async throws {
        let qa = try QAHarness(self)
        let first = try qa.makeProject(name: "Uno")
        let second = try qa.makeProject(name: "Dos")
        await qa.openProject(first)
        let profile = try await qa.addConnection(QAFixtures.connection("Compartida"))
        await qa.openProject(second)
        XCTAssertTrue(qa.controller.connections.profiles.contains { $0.id == profile.id },
                      "el catálogo es global, no del proyecto")
    }

    /// CON-06
    func testChangingTheEndpointDropsTheStoredPassword() async throws {
        let qa = try QAHarness(self)
        var connection = QAFixtures.connection("Con clave")
        connection.host = "127.0.0.1"
        try CredentialStore.save("Krabzik QA ephemeral", for: connection)
        addTeardownBlock { try? CredentialStore.remove(for: connection) }
        XCTAssertEqual(try CredentialStore.read(for: connection), "Krabzik QA ephemeral")
        for mutate in [{ (value: inout DatabaseConnection) in value.host = "otro.host" },
                       { value in value.port = 3307 },
                       { value in value.username = "otro" },
                       { value in value.tls = .required }] {
            var moved = connection
            mutate(&moved)
            XCTAssertTrue(ConnectionStore.endpointChanged(from: connection, to: moved))
            XCTAssertEqual(try CredentialStore.read(for: moved), "", "otro extremo no hereda la credencial")
        }
        _ = qa
    }

    /// CON-07
    func testTestingAClosedPortReportsATranslatedError() async throws {
        let qa = try QAHarness(self)
        var connection = QAFixtures.connection("Cerrada")
        connection.port = 9
        connection.connectTimeoutSeconds = 1
        do {
            try await qa.controller.database.client.test(connection, password: "")
            XCTFail("un puerto cerrado no puede conectar")
        } catch {
            let message = MySQLClient.message(error)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("NIOSSLError"), message)
            XCTAssertFalse(message.contains("Error Domain"), message)
        }
        await qa.controller.database.client.shutdown()
    }

    /// CON-09
    func testDisconnectingWithAnOpenTransactionAsksFirst() async throws {
        let qa = try QAHarness(self)
        let profile = try await qa.addConnection(QAFixtures.connection("Con transacción"))
        let state = qa.controller.database.state(profile.id)
        state.status = .connected
        state.inTransaction = true
        qa.script.disconnectWithTransaction = false
        let cancelled = await qa.controller.database.disconnect(profile)
        await qa.assertEvent("dialog.connection.disconnectWithTransaction", ["answer": "cancel"])
        XCTAssertFalse(cancelled)
        XCTAssertEqual(state.status, .connected, "cancelar conserva la conexión")

        qa.script.disconnectWithTransaction = true
        let closed = await qa.controller.database.disconnect(profile)
        await qa.assertEvent("dialog.connection.disconnectWithTransaction", ["answer": "close"])
        XCTAssertTrue(closed)
        XCTAssertEqual(state.status, .disconnected)
        XCTAssertFalse(state.inTransaction)
    }

    /// CON-10
    func testABusyConnectionDisablesItsCard() async throws {
        let qa = try QAHarness(self)
        let profile = try await qa.addConnection(QAFixtures.connection("Ocupada"))
        await qa.mount()
        qa.controller.database.showingConnections = true
        await qa.assertScreen("connections")
        await qa.assertControl("connections.card.edit.Ocupada", title: "Editar", enabled: true)
        await qa.assertControl("connections.card.toggle.Ocupada", title: "Conectar", enabled: true)

        qa.controller.database.state(profile.id).busy = true
        await qa.settle(until: { qa.control("connections.card.edit.Ocupada")?.enabled == false })
        await qa.assertControl("connections.card.edit.Ocupada", enabled: false)
        await qa.assertControl("connections.card.toggle.Ocupada", enabled: false)
        await qa.assertControl("connections.card.remove.Ocupada", enabled: false)
        qa.controller.database.state(profile.id).busy = false
    }

    /// CON-11
    func testRemovingAProfileLeavesItsScriptsWithoutConnection() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        let profile = try await qa.addConnection(QAFixtures.connection("Para quitar"))
        let document = try await qa.openScript("SELECT 1;\n", named: "uno.sql", connection: profile)
        XCTAssertNotNil(qa.controller.connections.selected(for: document))

        qa.controller.connections.remove(profile)
        await qa.settle(until: { qa.controller.connections.profiles.isEmpty })
        await qa.assertEvent("connection.remove.ok", ["name": "Para quitar"])
        XCTAssertNil(qa.controller.connections.selected(for: document),
                     "el script queda sin conexión asignada")
    }

    /// CON-12
    func testProjectProfilesAreImportedOnlyOnce() async throws {
        let qa = try QAHarness(self)
        let declared = QAFixtures.connection("Del proyecto")
        let url = try qa.makeProject(name: "ConConexión", connections: [declared])
        await qa.openProject(url)
        await qa.assertEvent("state.connections", ["imported": "1"])
        XCTAssertEqual(qa.controller.connections.profiles.count, 1)
        await qa.controller.closeWorkspace()
        await qa.openProject(url)
        XCTAssertEqual(qa.controller.connections.profiles.count, 1, "la importación es una sola vez")
    }

    /// CON-13
    func testAClashingProjectProfileEntersWithANewIdentity() async throws {
        let qa = try QAHarness(self)
        let mine = try await qa.addConnection(QAFixtures.connection("Mía"))
        var theirs = mine
        theirs.name = "Ajena"
        theirs.host = "10.0.0.9"
        let url = try qa.makeProject(name: "Ajeno", connections: [theirs])
        await qa.openProject(url)
        await qa.settle(until: { qa.controller.connections.profiles.count == 2 })
        XCTAssertEqual(qa.controller.connections.profiles.count, 2)
        let kept = try XCTUnwrap(qa.controller.connections.profiles.first { $0.id == mine.id })
        XCTAssertEqual(kept.name, "Mía", "el perfil que ya estaba no se modifica")
        XCTAssertEqual(kept.host, mine.host)
    }

    /// ABR-05
    func testReadOnlyProjectsDoNotImportTheirProfiles() async throws {
        let qa = try QAHarness(self)
        let declared = QAFixtures.connection("Del proyecto ajeno")
        let url = try qa.makeProject(name: "Ajeno", connections: [declared], trusted: false)
        qa.script.trust = .readOnly
        await qa.openProject(url)
        await qa.assertEvent("state.connections", ["imported": "0", "readOnly": "true"])
        XCTAssertTrue(qa.controller.connections.profiles.isEmpty)
    }

    /// CON-15
    func testDatabasePreferenceIsRemembered() async throws {
        let qa = try QAHarness(self)
        let profile = try await qa.addConnection(QAFixtures.connection("Con preferencia"))
        let schema = qa.controller.database.schema
        var preference = schema.preference(profile)
        preference.visible = ["qa", "reportes"]
        preference.defaultDatabase = "reportes"
        schema.save(preference, for: profile)
        XCTAssertEqual(schema.preference(profile).defaultDatabase, "reportes")
        XCTAssertEqual(schema.preference(profile).visible, ["qa", "reportes"])
    }

    /// CON-16
    func testPlaintextToARemoteHostIsFlagged() async throws {
        _ = try QAHarness(self)
        var local = QAFixtures.connection()
        local.host = "127.0.0.1"
        XCTAssertTrue(local.isLoopbackHost, "un host local sin cifrado es aceptable")
        var remote = QAFixtures.connection()
        remote.host = "db.example.com"
        XCTAssertFalse(remote.isLoopbackHost, "un host remoto sin cifrado tiene que advertirse")
    }

    /// CON-18
    func testEveryTLSModeExplainsWhatItVerifies() async throws {
        _ = try QAHarness(self)
        for mode in DatabaseConnection.TLSMode.allCases {
            XCTAssertFalse(mode.label.isEmpty, "\(mode)")
        }
        XCTAssertEqual(DatabaseConnection.TLSMode.allCases.count, 5)
    }

    /// EXP-03
    func testSchemaLoadingReportsProgressAndCanBeCancelled() async throws {
        let qa = try QAHarness(self)
        var connection = QAFixtures.connection("Sin servidor")
        connection.port = 9
        connection.connectTimeoutSeconds = 1
        let profile = try await qa.addConnection(connection)
        await qa.controller.database.schema.discover(profile, client: qa.controller.database.client)
        await qa.assertEvent("schema.discover.begin", ["connection": "Sin servidor", "choose": "false"])
        await qa.assertEvent("schema.discover.end")
        XCTAssertNotNil(qa.controller.database.schema.errors[profile.id],
                        "un servidor inalcanzable deja el motivo junto a la conexión")
        XCTAssertFalse(qa.controller.database.schema.loading.contains(profile.id))
        await qa.controller.database.client.shutdown()
    }

    /// ABR-10
    func testLeavingWithDatabaseWorkAsksBeforeClosing() async throws {
        let qa = try QAHarness(self)
        let profile = try await qa.addConnection(QAFixtures.connection("Con trabajo"))
        let state = qa.controller.database.state(profile.id)
        state.status = .connected
        state.inTransaction = true
        XCTAssertTrue(qa.controller.database.hasActiveWork)
        qa.script.closeActiveConnections = false
        let blocked = await qa.controller.database.prepareToLeave()
        await qa.assertEvent("dialog.connection.closeActive", ["answer": "cancel"])
        XCTAssertFalse(blocked)
        XCTAssertEqual(state.status, .connected)

        qa.script.closeActiveConnections = true
        let allowed = await qa.controller.database.prepareToLeave()
        XCTAssertTrue(allowed)
        XCTAssertEqual(state.status, .disconnected)
    }

    /// CON-08 · necesita el MySQL desechable
    func testConnectAndDisconnectFlipTheButtonTitle() async throws {
        let port = try QAFixtures.mysqlPort()
        let qa = try QAHarness(self)
        var connection = QAFixtures.connection("QA real")
        connection.port = port
        connection.database = "krabzik_qa"
        let profile = try await qa.addConnection(connection)
        await qa.mount()
        qa.controller.database.showingConnections = true
        await qa.assertScreen("connections")
        await qa.assertControl("connections.card.toggle.QA real", title: "Conectar", enabled: true)

        try await qa.tap("connections.card.toggle.QA real")
        await qa.settle(until: { qa.controller.database.state(profile.id).status == .connected }, timeout: 15)
        await qa.assertEvent("connection.connect.ok")
        await qa.settle(until: { qa.control("connections.card.toggle.QA real")?.title == "Desconectar" })
        await qa.assertControl("connections.card.toggle.QA real", title: "Desconectar")

        try await qa.tap("connections.card.toggle.QA real")
        await qa.settle(until: { qa.controller.database.state(profile.id).status == .disconnected }, timeout: 10)
        await qa.assertEvent("connection.disconnect.ok")
        await qa.controller.database.client.shutdown()
    }

    // MARK: -

    private func assertRejected(_ qa: QAHarness, _ connection: DatabaseConnection, _ why: String,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await qa.controller.connections.save(connection, password: "")
            XCTFail("tiene que rechazar: " + why, file: file, line: line)
        } catch {
            await qa.assertEvent("connection.save.rejected", file: file, line: line)
        }
    }
}
