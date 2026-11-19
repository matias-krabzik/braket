import Foundation
@testable import Krabzik
import XCTest

@MainActor final class SQLSubqueryEditingTests: XCTestCase {
    private func fixture(_ sql: String, name: String = "Passengers") -> (SQLResult, SQLSchemaTable) {
        let table = SQLSchemaTable(database: "qa", name: name, kind: "BASE TABLE", engine: "InnoDB", columns: [
            SQLSchemaColumn(name: "id", type: "bigint", nullable: false, extra: ""),
            SQLSchemaColumn(name: "name", type: "varchar(80)", nullable: true, extra: "")
        ], uniqueKeys: [["id"]], primaryKey: ["id"])
        var result = SQLResult(statement: 1, line: 1)
        result.sql = sql
        result.columns = ["id", "name"]
        result.origins = result.columns.map { SQLColumnOrigin(database: "qa", table: name, column: $0) }
        result.rows = [["9007199254740993", "Antes"], ["2", nil]]
        return (result, table)
    }

    func testUserQueriesAreEditableAndOnlyUpdateTheOuterTableByPrimaryKey() throws {
        let filter = "reservation_request_id IN (SELECT id FROM ReservationsRequests WHERE pnr=@PNR AND mor=@AIRLINE_ID)"
        for (name, sql) in [
            ("FlightsReservationsRequests", "SELECT * FROM FlightsReservationsRequests WHERE " + filter),
            ("Passengers", "SELECT * FROM Passengers WHERE Passengers.id IN (SELECT passenger_id FROM FlightsReservationsRequests WHERE "
             + filter + ")"),
            ("BuddyPassengers", "SELECT * FROM BuddyPassengers WHERE BuddyPassengers.id IN (SELECT entity_id FROM Passengers WHERE id IN "
             + "(SELECT passenger_id FROM FlightsReservationsRequests WHERE " + filter + "))")
        ] {
            let (result, table) = fixture(sql, name: name)
            let draft = SQLResultDraft(result: result)
            draft.configure(table)
            XCTAssertTrue(draft.canEdit, draft.reason)
            draft.set(.text("Nuevo"), row: 0, column: 1)
            let mutation = try XCTUnwrap(draft.mutations().first)
            XCTAssertEqual(mutation.sql, "UPDATE `qa`.`\(name)` SET `name` = 'Nuevo' WHERE `id` = 9007199254740993 LIMIT 1")
            XCTAssertEqual(mutation.verificationSQL,
                           "SELECT `id`, `name` FROM `qa`.`\(name)` WHERE `id` = 9007199254740993 LIMIT 2 FOR UPDATE")
            XCTAssertTrue(mutation.matchesOriginal([result.rows[0]]))
            XCTAssertFalse(mutation.matchesOriginal([["9007199254740993", "Cambio externo"]]))
            XCTAssertFalse(mutation.matchesOriginal([]))
            XCTAssertFalse(mutation.matchesOriginal([result.rows[0], result.rows[0]]))
        }
    }

    func testNestedFilterJoinsGroupsAliasesAndLiteralKeywordsAreAllowed() {
        for sql in [
            "-- SELECT JOIN\nSELECT p.* FROM `qa`.`Passengers` AS p WHERE p.id IN (SELECT DISTINCT x.id FROM other x JOIN third y "
                + "ON x.id=y.id GROUP BY x.id HAVING COUNT(*)>0) ORDER BY p.id LIMIT 100",
            "SELECT p.* FROM Passengers p WHERE EXISTS (SELECT 1 FROM other x WHERE x.id=p.id)",
            "SELECT * FROM Passengers WHERE (id NOT IN (SELECT id FROM other WHERE name='JOIN UNION SELECT'))",
            "SELECT * FROM Passengers WHERE name='a\\\'SELECT' AND id IN (SELECT id FROM other)",
            "SELECT * FROM Passengers WHERE id IN (SELECT id FROM other UNION SELECT id FROM another)"
        ] {
            let (result, table) = fixture(sql)
            XCTAssertNil(SQLResultDraft.readOnlyReason(result, table: table), sql)
        }
        var (result, table) = fixture("SELECT * FROM Passengers WHERE name='a\\' AND id IN (SELECT id FROM other)")
        result.noBackslashEscapes = true
        XCTAssertNil(SQLResultDraft.readOnlyReason(result, table: table))
    }

    func testOuterAmbiguityDerivedTablesExecutableCommentsAndOtherSubqueryPositionsStayReadOnly() {
        for sql in [
            "SELECT p.* FROM Passengers p JOIN other x ON p.id=x.id",
            "SELECT p.* FROM Passengers p, other x WHERE p.id=x.id",
            "SELECT * FROM Passengers UNION SELECT * FROM Passengers",
            "SELECT DISTINCT * FROM Passengers", "SELECT * FROM Passengers GROUP BY id",
            "SELECT * FROM (SELECT * FROM Passengers) Passengers",
            "SELECT (SELECT id FROM other) FROM Passengers",
            "SELECT * FROM Passengers ORDER BY (SELECT id FROM other LIMIT 1)",
            "SELECT * FROM other WHERE id IN (SELECT id FROM Passengers)",
            "SELECT * FROM Passengers /*! JOIN other USING(id) */",
            "SELECT * FROM Passengers; SELECT * FROM other",
            "SELECT * FROM Passengers; SELECT 'unterminated",
            "SELECT * FROM Passengers WHERE id IN ((SELECT id FROM other)",
            "WITH p AS (SELECT * FROM Passengers) SELECT * FROM p"
        ] {
            let (result, table) = fixture(sql)
            XCTAssertNotNil(SQLResultDraft.readOnlyReason(result, table: table), sql)
        }
    }

    func testPrimaryKeyMustBeCompleteAndEveryRowUnambiguous() {
        let (original, schema) = fixture("SELECT * FROM Passengers WHERE id IN (SELECT id FROM other)")
        var result = original, table = schema
        table.primaryKey = ["id", "missing"]
        XCTAssertNotNil(SQLResultDraft.readOnlyReason(result, table: table))
        table = schema
        result.rows[0][0] = nil
        XCTAssertNotNil(SQLResultDraft.readOnlyReason(result, table: table))
        result = original
        result.rows.append(result.rows[0])
        XCTAssertNotNil(SQLResultDraft.readOnlyReason(result, table: table))
        result = original
        result.rows[0] = []
        XCTAssertNotNil(SQLResultDraft.readOnlyReason(result, table: table))
        result = original
        result.origins[1].table = "other"
        XCTAssertNotNil(SQLResultDraft.readOnlyReason(result, table: table))
    }
    private actor Results {
        var values: [SQLResult] = []
        func append(_ value: SQLResult) { values.append(value) }
    }
    private func run(_ sql: String, client: MySQLClient, config: DatabaseConnection) async throws -> [SQLResult] {
        let sink = Results()
        _ = try await client.execute(sql, startingLine: 1, configuration: config, password: "", operation: UUID()) {
            await sink.append($0)
        }
        return await sink.values
    }

    func testRealMySQLNestedFiltersEditByPrimaryKeyAndRollBackOnConflict() async throws {
        let port = try QAFixtures.mysqlPort()
        var config = DatabaseConnection()
        config.port = port
        config.database = "krabzik_qa"
        config.tls = .disabled
        let client = MySQLClient()
        let cleanup = "DROP TABLE IF EXISTS braket_subq_r, braket_subq_f, braket_subq_p, braket_subq_b"
        do {
            _ = try await run(cleanup + ";" + """
            CREATE TABLE braket_subq_r(id INT PRIMARY KEY, pnr VARCHAR(20), mor INT) ENGINE=InnoDB;
            CREATE TABLE braket_subq_f(id INT PRIMARY KEY, reservation_request_id INT, passenger_id INT, name VARCHAR(80)) ENGINE=InnoDB;
            CREATE TABLE braket_subq_p(id INT PRIMARY KEY, entity_id INT, name VARCHAR(80)) ENGINE=InnoDB;
            CREATE TABLE braket_subq_b(id INT PRIMARY KEY, name VARCHAR(80)) ENGINE=InnoDB;
            INSERT INTO braket_subq_r VALUES (11,'QA',999);
            INSERT INTO braket_subq_f VALUES (101,11,201,'first'),(102,11,202,'second');
            INSERT INTO braket_subq_p VALUES (201,301,'first'),(202,302,'second');
            INSERT INTO braket_subq_b VALUES (301,'first'),(302,'second');
            SET @PNR='QA'; SET @AIRLINE_ID=999;
            """, client: client, config: config)
            let schema = try await client.schema(config, password: "", databases: [config.database])
            let filter = "reservation_request_id IN (SELECT id FROM braket_subq_r WHERE pnr=@PNR AND mor=@AIRLINE_ID)"
            let passengerFilter = "id IN (SELECT passenger_id FROM braket_subq_f WHERE " + filter + ")"
            for (name, sql) in [
                ("braket_subq_f", "SELECT * FROM braket_subq_f WHERE " + filter + " ORDER BY id"),
                ("braket_subq_p", "SELECT * FROM braket_subq_p WHERE " + passengerFilter + " ORDER BY id"),
                ("braket_subq_b", "SELECT * FROM braket_subq_b WHERE id IN (SELECT entity_id FROM braket_subq_p WHERE "
                 + passengerFilter + ") ORDER BY id")
            ] {
                let table = try XCTUnwrap(schema.tables.first { $0.name == name })
                let results = try await run(sql, client: client, config: config)
                let result = try XCTUnwrap(results.first)
                XCTAssertEqual(result.rows.count, 2)
                let column = try XCTUnwrap(result.columns.firstIndex(of: "name"))
                let draft = SQLResultDraft(result: result)
                draft.configure(table)
                XCTAssertTrue(draft.canEdit, draft.reason)
                draft.set(.text("updated"), row: 0, column: column)
                try await client.apply(draft.mutations(), table: table, configuration: config, password: "")
                let refreshed = try await run(sql, client: client, config: config)
                let current = try XCTUnwrap(refreshed.first)
                XCTAssertEqual(current.rows[0][column], "updated")
                let stale = SQLResultDraft(result: current)
                stale.configure(table)
                stale.set(.text("should roll back"), row: 0, column: column)
                stale.set(.text("should conflict"), row: 1, column: column)
                let id = try XCTUnwrap(current.rows[1][0])
                _ = try await run("UPDATE `" + name + "` SET name='external' WHERE id=" + id, client: client, config: config)
                do { try await client.apply(stale.mutations(), table: table, configuration: config, password: "")
                    XCTFail("Debe rechazar una fila modificada y revertir la primera actualización")
                } catch { XCTAssertTrue(MySQLClient.message(error).contains("fila cambió")) }
                let retained = try await run(sql, client: client, config: config)
                XCTAssertEqual(retained.first?.rows.map { $0[column] }, ["updated", "external"])
            }
            _ = try await run(cleanup, client: client, config: config)
        } catch {
            _ = try? await run(cleanup, client: client, config: config)
            await client.shutdown()
            throw error
        }
        await client.shutdown()
    }

}
