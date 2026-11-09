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

    private func configuration() throws -> DatabaseConnection {
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mysql-test-port")
        guard let value = try? String(contentsOf: marker, encoding: .utf8), let port = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw XCTSkip("Requiere la instancia de prueba local indicada en .build/mysql-test-port.")
        }
        var config = DatabaseConnection()
        config.port = port; config.database = "krabzik_qa"; config.tls = .disabled
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
        } catch { await client.shutdown(); throw error }
    }

    func testMySQLTransactionRollbackAndStopOnFirstError() async throws {
        let config = try configuration(), client = MySQLClient()
        do {
            _ = try await execute("CREATE TEMPORARY TABLE tx (id INT PRIMARY KEY); BEGIN; INSERT INTO tx VALUES(1);", client: client, config: config)
            let info = await client.info(config.id)
            XCTAssertEqual(info?.inTransaction, true)
            let results = try await execute("ROLLBACK; SELECT COUNT(*) FROM tx;", client: client, config: config)
            XCTAssertEqual(results[1].rows[0][0], "0")
            let sink = ResultSink()
            do {
                _ = try await client.execute("INSERT INTO tx VALUES(2); INVALID SQL; INSERT INTO tx VALUES(3);", startingLine: 1, configuration: config, password: "", operation: UUID()) { await sink.append($0) }
                XCTFail("El script debe detenerse en el error")
            } catch {}
            let partial = await sink.values
            XCTAssertEqual(partial.count, 2)
            XCTAssertNotNil(partial.last?.error)
            let rows = try await execute("SELECT id FROM tx", client: client, config: config)
            XCTAssertEqual(rows[0].rows, [["2"]])
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }

    func testMySQLBoundsResultsAndPreservesDuplicateColumnNames() async throws {
        let config = try configuration(), client = MySQLClient()
        do {
            let results = try await execute("SET SESSION cte_max_recursion_depth=2000; WITH RECURSIVE n AS (SELECT 1 AS x UNION ALL SELECT x+1 FROM n WHERE x<1500) SELECT x AS same, x AS same FROM n", client: client, config: config)
            XCTAssertEqual(results[1].columns, ["same", "same"])
            XCTAssertEqual(results[1].rowCount, 1500)
            XCTAssertEqual(results[1].rows.count, 1000)
            XCTAssertTrue(results[1].truncated)
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }

    func testMySQLCancellationClosesActualServerSession() async throws {
        let config = try configuration(), client = MySQLClient(), observer = MySQLClient()
        let operation = UUID()
        do {
            let idRows = try await execute("SELECT CONNECTION_ID()", client: client, config: config)
            let serverID = idRows[0].rows[0][0]!
            let job = Task { try await client.execute("SELECT SLEEP(30)", startingLine: 1, configuration: config, password: "", operation: operation) { _ in } }
            try await Task.sleep(nanoseconds: 200_000_000)
            await client.cancel(operation)
            do { _ = try await job.value; XCTFail("La consulta debe cancelarse") } catch is CancellationError {}
            let rows = try await execute("SELECT COUNT(*) FROM information_schema.processlist WHERE ID = \(serverID)", client: observer, config: config)
            XCTAssertEqual(rows[0].rows[0][0], "0")
            await client.shutdown(); await observer.shutdown()
        } catch { await client.shutdown(); await observer.shutdown(); throw error }
    }

    func testMySQLRejectsBadCredentialsAndUntrustedTLS() async throws {
        var config = try configuration()
        let client = MySQLClient()
        config.username = "krabzik_nonexistent_user"
        do { try await client.test(config, password: "invalid"); XCTFail("Debe rechazar al usuario inexistente") } catch {}
        config.username = "root"; config.tls = .verified
        do { try await client.test(config, password: ""); XCTFail("No debe aceptar el certificado autofirmado") } catch {}
        await client.shutdown()
    }

    func testMySQLPasswordAuthenticationAndStoredProcedure() async throws {
        let adminConfig = try configuration(), admin = MySQLClient(), client = MySQLClient()
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let user = "qa_\(suffix)", procedure = "qa_proc_\(suffix)"
        let password = "Prueba-\(UUID().uuidString)"
        do {
            _ = try await execute("CREATE USER '\(user)'@'%' IDENTIFIED WITH caching_sha2_password BY '\(password)'; GRANT ALL ON krabzik_qa.* TO '\(user)'@'%';", client: admin, config: adminConfig)
            var config = adminConfig; config.id = UUID(); config.username = user
            // First connection exercises full RSA auth; the next exercises cached auth.
            try await client.test(config, password: password)
            try await client.test(config, password: password)
            do { try await client.test(config, password: "wrong"); XCTFail("Debe rechazar una contraseña incorrecta") } catch {}
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
            await client.shutdown(); await admin.shutdown()
        } catch {
            _ = try? await execute("DROP PROCEDURE IF EXISTS \(procedure); DROP USER IF EXISTS '\(user)'@'%';", client: admin, config: adminConfig)
            await client.shutdown(); await admin.shutdown(); throw error
        }
    }

    func testCredentialsStayBoundToEndpointAndTLS() throws {
        let config = DatabaseConnection()
        defer { try? CredentialStore.remove(for: config) }
        try CredentialStore.save("Krabzik ephemeral test", for: config)
        XCTAssertEqual(try CredentialStore.read(for: config), "Krabzik ephemeral test")
        var changed = config; changed.host = "other.example"
        XCTAssertEqual(try CredentialStore.read(for: changed), "")
        changed = config; changed.tls = .disabled
        XCTAssertEqual(try CredentialStore.read(for: changed), "")
        try CredentialStore.save("", for: config)
        XCTAssertEqual(try CredentialStore.read(for: config), "")
    }

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
                    let connection = try await MySQLConnection.connect(to: server.localAddress!, username: "test", database: "",
                        tlsConfiguration: nil, connectTimeout: .milliseconds(150), on: group.next()).get()
                    try await connection.close().get()
                    XCTFail("Un servidor sin handshake no debe quedar conectado")
                } catch {}
                let child = try await accepted.futureResult.get()
                if child.isActive { try await child.close().get() }
                try await server.close().get()
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
