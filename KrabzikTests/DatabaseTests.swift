@testable import Krabzik
import MySQLNIO
import NIOCore
import NIOPosix
import XCTest

private actor ResultSink {
    var values: [SQLResult] = []
    func append(_ value: SQLResult) { values.append(value) }
}

final class DatabaseTests: XCTestCase {
    func testAdvancedConnectionSettingsRoundTripAndLegacyDefaults() throws {
        var value = DatabaseConnection()
        let legacy = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(DatabaseConnection.self, from: legacy).effectiveConnectTimeout, 10)
        value.connectTimeoutSeconds = 45
        value.tlsCAPath = "/tmp/ca.pem"
        value.tlsServerName = "db.example.com"
        value.tlsClientCertificatePath = "/tmp/client.pem"
        value.tlsClientKeyPath = "/tmp/client-key.pem"
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(DatabaseConnection.self, from: data), value)
        XCTAssertEqual(try value.validated().effectiveConnectTimeout, 45)
    }

    func testAdvancedConnectionValidation() throws {
        var value = DatabaseConnection()
        value.connectTimeoutSeconds = 0
        XCTAssertThrowsError(try value.validated())
        value.connectTimeoutSeconds = 301
        XCTAssertThrowsError(try value.validated())
        value.connectTimeoutSeconds = 30
        value.tlsClientCertificatePath = "/tmp/client.pem"
        XCTAssertThrowsError(try value.validated())
        value.tlsClientKeyPath = "/tmp/key.pem"
        value.tlsServerName = " bad\nname "
        XCTAssertThrowsError(try value.validated())
        value.tlsServerName = " db.example.com "
        XCTAssertEqual(try value.validated().tlsServerName, "db.example.com")
    }

    private func split(_ sql: String) throws -> [SQLStatement] {
        var cursor = SQLScript(sql)
        var statements: [SQLStatement] = []
        while let statement = try cursor.next() { statements.append(statement) }
        return statements
    }

    func testScriptHandlesStringsCommentsAndCustomDelimiters() throws {
        let statements = try split("""
        -- a ; inside a comment
        SELECT 'a;b', "c;d", `a;b`;
        # another ; comment
        DELIMITER $$
        CREATE PROCEDURE p()
        BEGIN
          SELECT 'quote '' ; inside';
          SELECT 2;
        END$$
        DELIMITER ;
        /* comment ; */ SELECT 3;
        """)
        XCTAssertEqual(statements.count, 3)
        XCTAssertTrue(statements[1].text.contains("SELECT 2;"))
        XCTAssertTrue(statements[2].text.hasSuffix("SELECT 3"))
        XCTAssertEqual(statements[0].line, 2)
    }

    func testScriptDistinguishesCommentsAndExecutableComments() throws {
        XCTAssertEqual(try split("-- nothing\n# nothing\n/* nothing */;;").count, 0)
        XCTAssertEqual(try split("/*!40101 SET @x = 1 */; SELECT 2--1;").count, 2)
        XCTAssertEqual(try split("SELECT 'escaped \\' ; text'; SELECT 2;").count, 2)
        XCTAssertThrowsError(try split("SELECT 'unterminated"))
        XCTAssertThrowsError(try split("/* unterminated"))
    }

    func testParserHonorsChangedBackslashMode() throws {
        var cursor = SQLScript("SET sql_mode='NO_BACKSLASH_ESCAPES'; SELECT '\\'; SELECT 2;")
        XCTAssertNotNil(try cursor.next())
        XCTAssertEqual(try cursor.next(noBackslashEscapes: true)?.text, "SELECT '\\'")
        XCTAssertEqual(try cursor.next(noBackslashEscapes: true)?.text, "SELECT 2")
    }

    func testOldWorkspacesLoadAndCredentialsAreNotSerialized() throws {
        let old = Data(#"{"version":1,"name":"Old","projects":[]}"#.utf8)
        var workspace = try JSONDecoder().decode(Workspace.self, from: old)
        XCTAssertTrue(workspace.connections.isEmpty)
        workspace.connections = [DatabaseConnection()]
        let encoded = try JSONEncoder().encode(workspace)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("password"))
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: encoded), workspace)
    }

    @MainActor func testSQLSelectionUsesUTF16AndOriginalLine() async throws {
        let text = "-- 🦀\nSELECT 1;\nSELECT 2;"
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/selection.sql"), data: Data(text.utf8))
        document.selectedRange = (text as NSString).range(of: "SELECT 2;")
        XCTAssertEqual(document.sqlToExecute.text, "SELECT 2;")
        XCTAssertEqual(document.sqlToExecute.startingLine, 3)
        document.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertEqual(document.sqlToExecute.text, text)
    }

    func testLoopbackDetectionCoversAliasesAndRanges() {
        var config = DatabaseConnection()
        let locales = ["127.0.0.1", "127.1.2.3", "127.0.0.255", "::1", "[::1]",
                       "localhost", "LOCALHOST", "api.localhost"]
        let remotos = ["localhost.attacker.example", "0.0.0.0", "192.168.1.10",
                       "127.malicioso.example", "127.0.0", "db.interno.example", ""]
        for host in locales {
            config.host = host
            XCTAssertTrue(config.isLoopbackHost, "\(host) debería ser local")
        }
        for host in remotos {
            config.host = host
            XCTAssertFalse(config.isLoopbackHost, "\(host) no debería ser local")
        }
    }

    func testNoTLSCanBeSavedForRemoteTCPWithVisibleMode() throws {
        var config = DatabaseConnection()
        config.host = "db.interno.example"
        config.tls = .disabled
        XCTAssertNoThrow(try config.validated())
        // El mismo perfil con TLS verificado es válido, y en loopback también sin TLS.
        config.tls = .verified
        XCTAssertNoThrow(try config.validated())
        config.tls = .disabled
        config.host = "127.0.0.1"
        XCTAssertNoThrow(try config.validated())
    }

    func testWorkspaceWithRemoteInsecureConnectionStillLoads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krabzik-s3-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var config = DatabaseConnection()
        config.host = "db.interno.example"
        config.tls = .disabled
        let url = directory.appendingPathComponent("remoto.krabzik")
        var workspace = Workspace(name: "remoto")
        workspace.connections = [config]
        try workspace.write(to: url)
        // Leer no rechaza: rechazar dejaría el proyecto inabrible.
        let read = try Workspace.read(from: url)
        XCTAssertEqual(read.connections.first?.host, "db.interno.example")
        XCTAssertEqual(read.connections.first?.tls, .disabled)
    }

    func testNoTLSRemoteProfileValidatesWithoutChangingItsMode() throws {
        var config = DatabaseConnection()
        config.host = "93.184.216.34"
        config.tls = .disabled
        XCTAssertEqual(try config.validated().tls, .disabled)
    }

    func testCancellationReportsWhenCredentialIsUnavailable() async throws {
        let config = try configuration()
        // Lector que falla: simula que el llavero no está disponible al cancelar,
        // sin tocar el llavero real.
        let client = MySQLClient { _ in throw DatabaseFailure("llavero no disponible") }
        let operation = UUID()
        let started = expectation(description: "la consulta arrancó")
        let task = Task {
            started.fulfill()
            _ = try? await client.execute("SELECT SLEEP(5)", startingLine: 1, configuration: config,
                                          password: "", operation: operation) { _ in }
        }
        await fulfillment(of: [started], timeout: 5)
        try await Task.sleep(nanoseconds: 400_000_000)
        let outcome = await client.cancel(operation)
        task.cancel()
        guard case .localOnly(let reason) = outcome else {
            XCTFail("Debe informar que solo se cerró la conexión local, no \(outcome)")
            await client.shutdown()
            return
        }
        XCTAssertTrue(reason.contains("llavero no disponible"), reason)
        await client.shutdown()
    }

    private func configuration() throws -> DatabaseConnection {
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mysql-test-port")
        guard let value = try? String(contentsOf: marker, encoding: .utf8),
              let port = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw XCTSkip("Requiere la instancia de prueba local indicada en .build/mysql-test-port.")
        }
        var config = DatabaseConnection()
        config.port = port
        config.database = "krabzik_qa"
        config.tls = .disabled
        return config
    }

    private func execute(_ sql: String, client: MySQLClient, config: DatabaseConnection) async throws -> [SQLResult] {
        let sink = ResultSink()
        _ = try await client.execute(sql, startingLine: 1, configuration: config, password: "", operation: UUID()) { await sink.append($0) }
        return await sink.values
    }

    func testMySQLTypesEmptyResultsAffectedRowsAndSession() async throws {
        let config = try configuration(), client = MySQLClient()
        do {
            let results = try await execute("""
            CREATE TEMPORARY TABLE sample (id INT PRIMARY KEY, name VARCHAR(50), amount DECIMAL(20,4));
            INSERT INTO sample VALUES (1,'Café 🦀',123456789.1250),(2,NULL,0);
            SELECT id, name, amount, NULL AS nil_value, '' AS empty_value, 'NULL' AS null_text, 0x00FF AS bytes FROM sample ORDER BY id;
            SELECT id, name FROM sample WHERE id = 100;
            UPDATE sample SET name = 'Updated' WHERE id = 2;
            """, client: client, config: config)
            XCTAssertEqual(results.count, 5)
            XCTAssertEqual(results[1].affectedRows, 2)
            XCTAssertEqual(results[2].rows[0][1], "Café 🦀")
            XCTAssertEqual(results[2].rows[0][2], "123456789.1250")
            XCTAssertNil(results[2].rows[0][3])
            XCTAssertEqual(results[2].rows[0][4], "")
            XCTAssertEqual(results[2].rows[0][5], "NULL")
            XCTAssertEqual(results[2].rows[0][6], "0x00FF")
            XCTAssertEqual(results[3].columns, ["id", "name"])
            XCTAssertTrue(results[3].rows.isEmpty)
            XCTAssertEqual(results[4].affectedRows, 1)
            let next = try await execute("SELECT COUNT(*) FROM sample", client: client, config: config)
            XCTAssertEqual(next[0].rows[0][0], "2")
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    func testMySQLTransactionRollbackAndStopOnFirstError() async throws {
        let config = try configuration(), client = MySQLClient()
        do {
            _ = try await execute("CREATE TEMPORARY TABLE tx (id INT PRIMARY KEY); BEGIN; INSERT INTO tx VALUES(1);", client: client,
                                  config: config)
            let info = await client.info(config.id)
            XCTAssertEqual(info?.inTransaction, true)
            let results = try await execute("ROLLBACK; SELECT COUNT(*) FROM tx;", client: client, config: config)
            XCTAssertEqual(results[1].rows[0][0], "0")
            let sink = ResultSink()
            do {
                _ = try await client.execute("INSERT INTO tx VALUES(2); INVALID SQL; INSERT INTO tx VALUES(3);", startingLine: 1,
                                             configuration: config, password: "", operation: UUID()) { await sink.append($0) }
                XCTFail("El script debe detenerse en el error")
            } catch {}
            let partial = await sink.values
            XCTAssertEqual(partial.count, 2)
            XCTAssertNotNil(partial.last?.error)
            let rows = try await execute("SELECT id FROM tx", client: client, config: config)
            XCTAssertEqual(rows[0].rows, [["2"]])
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    func testMySQLBoundsResultsAndPreservesDuplicateColumnNames() async throws {
        let config = try configuration(), client = MySQLClient()
        do {
            let recursiva = "SET SESSION cte_max_recursion_depth=2000;"
                + " WITH RECURSIVE n AS (SELECT 1 AS x UNION ALL SELECT x+1 FROM n WHERE x<1500)"
                + " SELECT x AS same, x AS same FROM n"
            let results = try await execute(recursiva, client: client, config: config)
            XCTAssertEqual(results[1].columns, ["same", "same"])
            XCTAssertEqual(results[1].rowCount, 1500)
            XCTAssertEqual(results[1].rows.count, 1000)
            XCTAssertTrue(results[1].truncated)
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    func testMySQLCancellationClosesActualServerSession() async throws {
        let config = try configuration(), client = MySQLClient(), observer = MySQLClient()
        let operation = UUID()
        do {
            let idRows = try await execute("SELECT CONNECTION_ID()", client: client, config: config)
            let serverID = try XCTUnwrap(idRows[0].rows[0][0])
            let job = Task { try await client.execute("SELECT SLEEP(30)", startingLine: 1, configuration: config, password: "",
                                                      operation: operation) { _ in } }
            try await Task.sleep(nanoseconds: 200_000_000)
            await client.cancel(operation)
            do {
                _ = try await job.value
                XCTFail("La consulta debe cancelarse") } catch is CancellationError {}
            let rows = try await execute("SELECT COUNT(*) FROM information_schema.processlist WHERE ID = \(serverID)", client: observer,
                                         config: config)
            XCTAssertEqual(rows[0].rows[0][0], "0")
            await client.shutdown()
            await observer.shutdown()
        } catch {
            await client.shutdown()
            await observer.shutdown()
            throw error
        }
    }

    /// Cubre el parche 0001 del vendoring (rechazar TLS que el servidor no anuncia).
    /// Ver Vendor/MySQLNIO/patches/0001-reject-tls-when-server-does-not-advertise.patch
    func testMySQLRejectsBadCredentialsAndUntrustedTLS() async throws {
        var config = try configuration()
        let client = MySQLClient()
        config.username = "krabzik_nonexistent_user"
        do {
            try await client.test(config, password: "invalid")
            XCTFail("Debe rechazar al usuario inexistente") } catch {}
        config.username = "root"
        config.tls = .verified
        do {
            try await client.test(config, password: "")
            XCTFail("No debe aceptar el certificado autofirmado") } catch {}
        await client.shutdown()
    }

    /// Cubre dos parches del vendoring: el nonce de 20 bytes de `caching_sha2_password`
    /// —con una contraseña más larga que el nonce, y la autenticación en caché de la
    /// segunda conexión— y `CLIENT_MULTI_RESULTS`, que es lo que permite el `CALL`.
    /// Ver patches/0002-caching-sha2-nonce-20-bytes.patch y 0004-negotiate-client-multi-results.patch
    func testMySQLPasswordAuthenticationAndStoredProcedure() async throws {
        let adminConfig = try configuration(), admin = MySQLClient(), client = MySQLClient()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let user = "qa_\(suffix)", procedure = "qa_proc_\(suffix)"
        let password = "Prueba-\(UUID().uuidString)"
        do {
            let alta = "CREATE USER '\(user)'@'%' IDENTIFIED WITH caching_sha2_password"
                + " BY '\(password)'; GRANT ALL ON krabzik_qa.* TO '\(user)'@'%';"
            _ = try await execute(alta, client: admin, config: adminConfig)
            var config = adminConfig
            config.id = UUID()
            config.username = user
            // First connection exercises full RSA auth; the next exercises cached auth.
            try await client.test(config, password: password)
            try await client.test(config, password: password)
            do {
                try await client.test(config, password: "wrong")
                XCTFail("Debe rechazar una contraseña incorrecta") } catch {}
            let sink = ResultSink()
            _ = try await client.execute("""
            DELIMITER $$
            CREATE PROCEDURE \(procedure)()
            BEGIN
              SELECT 'uno;dos' AS value;
              SELECT 2 AS second;
            END$$
            DELIMITER ;
            CALL \(procedure)();
            DROP PROCEDURE \(procedure);
            SET sql_mode='NO_BACKSLASH_ESCAPES';
            SELECT '\\' AS slash;
            """, startingLine: 1, configuration: config, password: password, operation: UUID()) { await sink.append($0) }
            let results = await sink.values
            XCTAssertEqual(results[1].rows, [["uno;dos"]])
            XCTAssertEqual(results[2].rows, [["2"]])
            XCTAssertEqual(results.last?.rows, [["\\"]])
            _ = try await execute("DROP USER '\(user)'@'%';", client: admin, config: adminConfig)
            await client.shutdown()
            await admin.shutdown()
        } catch {
            _ = try? await execute("DROP PROCEDURE IF EXISTS \(procedure); DROP USER IF EXISTS '\(user)'@'%';", client: admin,
                                   config: adminConfig)
            await client.shutdown()
            await admin.shutdown()
            throw error
        }
    }

    /// Editar el extremo de una conexión tiene que borrar la credencial vieja: si no, en
    /// el llavero queda una contraseña que el usuario cree que ya no está. Es el camino de
    /// `saveConnection` que antes se tragaba el error con `try?` (C6, C9).
    @MainActor func testEditingEndpointRemovesTheOldCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-cred-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "krabzik-cred-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var vieja = DatabaseConnection()
        vieja.name = "local"
        vieja.host = "127.0.0.1"
        vieja.port = 3306
        vieja.username = "krabzik_qa"
        vieja.tls = .disabled
        var nueva = vieja
        nueva.port = 3307
        addTeardownBlock {
            try? CredentialStore.remove(for: vieja)
            try? CredentialStore.remove(for: nueva)
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }

        let url = directory.appendingPathComponent("Proyecto.krabzik")
        var workspace = Workspace(name: "Proyecto")
        workspace.connections = [vieja]
        try workspace.write(to: url)
        let controller = WorkspaceController(defaults: defaults)
        controller.confirmTrust = { _ in .trust }
        await controller.openWorkspace(url)
        XCTAssertEqual(controller.workspace?.connections.count, 1)

        try CredentialStore.save("secreto-de-prueba", for: vieja)
        XCTAssertEqual(try CredentialStore.read(for: vieja), "secreto-de-prueba")

        try await controller.connections.save(nueva, password: "secreto-de-prueba")

        XCTAssertEqual(try CredentialStore.read(for: vieja), "",
                       "la credencial del extremo anterior no puede quedar en el llavero")
        XCTAssertEqual(try CredentialStore.read(for: nueva), "secreto-de-prueba")
        XCTAssertNil(controller.errors.current)
    }

    func testCredentialsStayBoundToEndpointAndTLS() throws {
        let config = DatabaseConnection()
        defer { try? CredentialStore.remove(for: config) }
        try CredentialStore.save("Krabzik ephemeral test", for: config)
        XCTAssertEqual(try CredentialStore.read(for: config), "Krabzik ephemeral test")
        var changed = config
        changed.host = "other.example"
        XCTAssertEqual(try CredentialStore.read(for: changed), "")
        changed = config
        changed.tls = .disabled
        XCTAssertEqual(try CredentialStore.read(for: changed), "")
        try CredentialStore.save("", for: config)
        XCTAssertEqual(try CredentialStore.read(for: config), "")
    }

    /// Cubre el parche 0003 del vendoring: plazos de conexión y autenticación, y cierre
    /// del canal cuando el servidor corta antes de terminar.
    /// Ver patches/0003-connection-deadlines-and-channel-cleanup.patch
    func testHandshakeTimeoutAndEarlyServerDisconnect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for closeImmediately in [false, true] {
                let accepted = group.next().makePromise(of: (any Channel).self)
                let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    accepted.succeed(channel)
                    return closeImmediately ? channel.close() : channel.eventLoop.makeSucceededVoidFuture()
                }.bind(host: "127.0.0.1", port: 0).get()
                do {
                    let address = try XCTUnwrap(server.localAddress)
                    let connection = try await MySQLConnection.connect(to: address, username: "test", database: "",
                                                                       tlsConfiguration: nil, connectTimeout: .milliseconds(150),
                                                                       on: group.next()).get()
                    try await connection.close().get()
                    XCTFail("Un servidor sin handshake no debe quedar conectado")
                } catch {}
                let child = try await accepted.futureResult.get()
                if child.isActive { try await child.close().get() }
                try await server.close().get()
            }
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
