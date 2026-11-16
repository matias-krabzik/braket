@testable import Krabzik
import XCTest

final class SQLWriteGuardTests: XCTestCase {
    private func effect(_ sql: String, noBackslashEscapes: Bool = false) -> SQLStatementEffect {
        SQLWriteGuard.effect(of: sql, noBackslashEscapes: noBackslashEscapes)
    }

    func testOnlyRecognizedFormsCountAsReads() {
        let reads = [
            "SELECT 1",
            "select id, name from users where name = 'DELETE'",
            "  SELECT * FROM (SELECT id FROM t) AS inner_query",
            "WITH reciente AS (SELECT id FROM pedidos) SELECT * FROM reciente",
            "SHOW CREATE TABLE `users`",
            "SHOW VARIABLES LIKE 'sql_mode'",
            "DESCRIBE users",
            "DESC `users`",
            "EXPLAIN SELECT * FROM users",
            "EXPLAIN FORMAT=JSON SELECT 1",
            "USE krabzik_qa",
            "SET sql_mode = 'NO_BACKSLASH_ESCAPES'",
            "SET @actual = 3",
            "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED",
            "SET NAMES utf8mb4",
            "START TRANSACTION",
            "COMMIT",
            "ROLLBACK",
        ]
        for sql in reads {
            XCTAssertEqual(effect(sql), .read, sql)
        }
    }

    func testWritesAndAnythingNotRecognizedFailClosed() {
        let writes = [
            "UPDATE users SET name = 'x'",
            "DELETE FROM users",
            "INSERT INTO users (name) VALUES ('x')",
            "REPLACE INTO users (id, name) VALUES (1, 'x')",
            "DROP TABLE users",
            "TRUNCATE TABLE users",
            "ALTER TABLE users ADD COLUMN edad INT",
            "CREATE TABLE t (id INT)",
            "RENAME TABLE a TO b",
            "CALL recalcular()",
            "LOAD DATA INFILE '/tmp/x.csv' INTO TABLE users",
            "GRANT ALL ON *.* TO 'x'@'%'",
            "REVOKE ALL ON *.* FROM 'x'@'%'",
            "FLUSH TABLES",
            "KILL 42",
            "ANALYZE TABLE users",
            "OPTIMIZE TABLE users",
            "LOCK TABLES users WRITE",
            // El bloqueo y la salida no son lecturas inocuas.
            "SELECT * FROM users FOR UPDATE",
            "SELECT * FROM users FOR SHARE",
            "SELECT * FROM users LOCK IN SHARE MODE",
            "SELECT id INTO @ultimo FROM users",
            "SELECT * FROM users INTO OUTFILE '/tmp/x'",
            "SELECT * INTO copia FROM users",
            // MySQL 8 admite CTE delante de un DML.
            "WITH viejos AS (SELECT id FROM users) DELETE FROM users WHERE id IN (SELECT id FROM viejos)",
            "WITH x AS (SELECT 1) UPDATE users SET name = 'x'",
            // Un WITH que no llega a ningún SELECT no se reconoce.
            "WITH x AS (VALUES ROW(1))",
            // EXPLAIN ANALYZE ejecuta la consulta de verdad.
            "EXPLAIN ANALYZE SELECT * FROM users",
            "EXPLAIN DELETE FROM users",
            "EXPLAIN SELECT * FROM users FOR UPDATE",
            // SET que toca el servidor, no la sesión.
            "SET GLOBAL max_connections = 10",
            "SET @@GLOBAL.max_connections = 10",
            "SET PERSIST max_connections = 10",
            "SET PASSWORD FOR 'x'@'%' = 'y'",
            "SET DEFAULT ROLE admin TO 'x'@'%'",
            // START que no abre una transacción.
            "START REPLICA",
            // Palabras que esta versión no reconoce, y sentencias sin ninguna palabra.
            "BEGIN",
            "SAVEPOINT antes",
            "TABLE users",
            "HELP 'select'",
            "CHECKSUM TABLE users",
            "ñoño 1",
            "1 + 1",
            "'solo una cadena'",
            // Comentario ejecutable: es SQL que el servidor corre.
            "/*!40101 SET @x = 1 */",
            "/*M!999999 DELETE FROM users */",
            "SELECT 1 /*! , (SELECT 1 FROM users FOR UPDATE) */",
        ]
        for sql in writes {
            XCTAssertEqual(effect(sql), .write, sql)
        }
    }

    func testStringsCommentsAndIdentifiersDoNotChangeTheVerdict() {
        // Un DELETE dentro de una cadena o de un comentario no es una sentencia.
        XCTAssertEqual(effect("SELECT '; DELETE FROM users; --'"), .read)
        XCTAssertEqual(effect("SELECT \"UPDATE users SET a = 1\" AS texto"), .read)
        XCTAssertEqual(effect("-- UPDATE users\n# DROP TABLE users\n/* DELETE */ SELECT 1"), .read)
        XCTAssertEqual(effect("SELECT `for`, `into` FROM `update`"), .read)
        XCTAssertEqual(effect("SELECT 'a\\' FOR UPDATE'"), .read)
        // Con NO_BACKSLASH_ESCAPES la cadena cierra en la comilla y lo que sigue es código.
        XCTAssertEqual(effect("SELECT 'a\\' FOR UPDATE'", noBackslashEscapes: true), .write)
        // Una palabra clave en minúsculas o partida en varias líneas se reconoce igual.
        XCTAssertEqual(effect("select *\n  from users\n  for\n  update"), .write)
    }

    func testAuditClassifiesEveryStatementOfTheScript() throws {
        let audit = try SQLWriteGuard.audit("""
        SELECT 1;
        -- un comentario con ; adentro
        UPDATE users SET name = 'x' WHERE id = 1;
        SELECT 'texto; con punto y coma';
        DELETE FROM users WHERE id = 2;
        """)
        XCTAssertEqual(audit.total, 4)
        XCTAssertEqual(audit.writes.count, 2)
        XCTAssertTrue(audit.hasWrites)
        XCTAssertEqual(audit.writes.map(\.line), [3, 5])
        XCTAssertEqual(audit.preview(limit: 1), ["Línea 3: UPDATE users SET name = 'x' WHERE id = 1"])
    }

    func testAuditFollowsDelimiterAndCountsRoutinesOnce() throws {
        let audit = try SQLWriteGuard.audit("""
        SELECT 1;
        DELIMITER $$
        CREATE PROCEDURE p()
        BEGIN
          SELECT 2;
          DELETE FROM users;
        END$$
        DELIMITER ;
        SELECT 3;
        """)
        XCTAssertEqual(audit.total, 3)
        XCTAssertEqual(audit.writes.count, 1)
        XCTAssertEqual(audit.writes.first?.line, 3)
        // Una cadena sin cerrar no se puede clasificar: el audit lanza en vez de afirmar.
        XCTAssertThrowsError(try SQLWriteGuard.audit("SELECT 'sin cerrar"))
        XCTAssertEqual(try SQLWriteGuard.audit("-- nada\n").total, 0)
    }

    func testProfileRoundTripsWithAndWithoutThePolicy() throws {
        let legacy = """
        {"id":"7B8B0C6E-0000-4000-8000-000000000001","name":"Vieja","host":"10.0.0.5","port":3306,
         "username":"root","database":"ventas","tls":"verified"}
        """
        let old = try JSONDecoder().decode(DatabaseConnection.self, from: Data(legacy.utf8))
        XCTAssertNil(old.writePolicy)
        XCTAssertEqual(old.effectiveWritePolicy, .unrestricted)
        var value = DatabaseConnection(name: "Producción")
        value.writePolicy = DatabaseConnection.WritePolicy.readOnly.rawValue
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.effectiveWritePolicy, .readOnly)
        XCTAssertEqual(try value.validated().effectiveWritePolicy, .readOnly)
        value.writePolicy = "confirm"
        XCTAssertEqual(try value.validated().effectiveWritePolicy, .confirm)
        value.writePolicy = "   "
        XCTAssertNil(try value.validated().writePolicy)
    }

    func testUnknownPolicyBlocksSavingAndReadsAsTheStrictestLevel() throws {
        var value = DatabaseConnection(name: "Rara")
        value.writePolicy = "escribi-nomas"
        XCTAssertThrowsError(try value.validated())
        XCTAssertEqual(try value.validated(.lenient).effectiveWritePolicy, .readOnly)
        // Un .kzk con una política desconocida tiene que seguir abriéndose.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("politica-" + UUID().uuidString + ".kzk")
        try JSONEncoder().encode(Workspace(name: "Rara", connections: [value])).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let loaded = try Workspace.read(from: url)
        XCTAssertEqual(loaded.connections.first?.effectiveWritePolicy, .readOnly)
    }
}
