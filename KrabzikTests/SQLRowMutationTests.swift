import Foundation
@testable import Krabzik
import XCTest

@MainActor final class SQLRowMutationTests: XCTestCase {
    private func fixture() -> (SQLResultDraft, SQLSchemaTable) {
        let columns = [
            SQLSchemaColumn(name: "id", type: "bigint unsigned", nullable: false, extra: ""),
            SQLSchemaColumn(name: "email", type: "varchar(100)", nullable: false, extra: ""),
            SQLSchemaColumn(name: "name", type: "varchar(60)", nullable: true, extra: "")
        ]
        let table = SQLSchemaTable(database: "qa", name: "users", kind: "BASE TABLE", engine: "InnoDB", columns: columns,
                                   uniqueKeys: [["email"], ["id"]], primaryKey: ["id"])
        var result = SQLResult(statement: 1, line: 1)
        result.sql = "SELECT id, email, name FROM users"
        result.columns = columns.map(\.name)
        result.origins = columns.map { SQLColumnOrigin(database: "qa", table: "users", column: $0.name) }
        result.rows = [["9007199254740993", "old@example.test", "Before"], ["2", "other@example.test", nil]]
        let draft = SQLResultDraft(result: result)
        draft.configure(table)
        return (draft, table)
    }

    func testReadableLiteralsAndSpecialCharactersAreModeIndependent() throws {
        XCTAssertEqual(SQLValue.literal(nil), "NULL")
        XCTAssertEqual(SQLValue.literal(""), "''")
        XCTAssertEqual(SQLValue.literal("O'Brien 😀"), "'O''Brien 😀'")
        XCTAssertEqual(SQLValue.literal("123"), "'123'")
        XCTAssertEqual(SQLValue.literal("\\"), "CHAR(92 USING utf8mb4)")
        XCTAssertEqual(SQLValue.literal("a\\b"), "CONCAT('a', CHAR(92 USING utf8mb4), 'b')")
        XCTAssertEqual(SQLValue.literal("a\0b"), "CONCAT('a', CHAR(0 USING utf8mb4), 'b')")
        let hostile = "'\\'; DELETE FROM users; -- 😀"
        let literal = SQLValue.literal(hostile)
        for noBackslash in [false, true] {
            var script = SQLScript("SELECT " + literal)
            XCTAssertNotNil(try script.next(noBackslashEscapes: noBackslash))
            XCTAssertNil(try script.next(noBackslashEscapes: noBackslash))
        }
    }

    func testPrimaryKeyPredicateAndFullOriginalSnapshot() throws {
        let (draft, _) = fixture()
        draft.set(.text("After"), row: 0, column: 2)
        let mutation = try XCTUnwrap(draft.mutations().first)
        XCTAssertTrue(mutation.sql.hasSuffix("WHERE `id` = 9007199254740993 LIMIT 1"))
        XCTAssertFalse(mutation.sql.contains("CAST("))
        XCTAssertFalse(mutation.sql.contains("CONVERT("))
        XCTAssertTrue(mutation.sql.contains("SET `name` = 'After'"))
        XCTAssertFalse(mutation.sql.contains("AND `email`"))
        XCTAssertEqual(mutation.verificationSQL,
                       "SELECT `id`, `email`, `name` FROM `qa`.`users` WHERE `id` = 9007199254740993 LIMIT 2 FOR UPDATE")
        XCTAssertTrue(mutation.matchesOriginal([draft.result.rows[0]]))
        var changed = draft.result.rows[0]
        changed[1] = "external@example.test"
        XCTAssertFalse(mutation.matchesOriginal([changed]), "Detecta cambios incluso en campos que no editamos")
        XCTAssertFalse(mutation.matchesOriginal([]))
        XCTAssertFalse(mutation.matchesOriginal([draft.result.rows[0], draft.result.rows[0]]))
    }

    func testOriginalKeyIsUsedWhenKeyIsEditedAndDeleted() throws {
        let (draft, _) = fixture()
        draft.set(.text("10"), row: 0, column: 0)
        XCTAssertTrue(try draft.mutations()[0].sql.hasSuffix("WHERE `id` = 9007199254740993 LIMIT 1"))
        draft.deleteRow(1)
        let deletion = try XCTUnwrap(draft.mutations().last)
        XCTAssertEqual(deletion.sql, "DELETE FROM `qa`.`users` WHERE `id` = 2 LIMIT 1")
        XCTAssertEqual(deletion.originalRow, draft.result.rows[1])
    }

    func testCompositePrimaryKeyAndUniqueFallback() throws {
        let (original, schema) = fixture()
        var table = schema
        table.primaryKey = ["id", "email"]
        let draft = SQLResultDraft(result: original.result)
        draft.configure(table)
        draft.set(.null, row: 0, column: 2)
        let sql = try draft.mutations()[0].sql
        XCTAssertTrue(sql.contains("WHERE `id` = 9007199254740993 AND `email` = 'old@example.test' LIMIT 1"))
        XCTAssertEqual(table.editingKey(in: ["email", "name"]), nil, "No sustituir una PK incompleta por otra clave")
        table.primaryKey = []
        XCTAssertEqual(table.editingKey(in: ["email", "name"]), ["email"])
    }

    func testConflictComparisonIsByteExactAndNullSafe() {
        let mutation = SQLMutation(sql: "", originalRow: ["é", nil, "1", "a "])
        XCTAssertTrue(mutation.matchesOriginal([["é", nil, "1", "a "]]))
        XCTAssertFalse(mutation.matchesOriginal([["e\u{301}", nil, "1", "a "]]))
        XCTAssertFalse(mutation.matchesOriginal([["é", "", "1", "a "]]))
        XCTAssertFalse(mutation.matchesOriginal([["é", nil, "1.0", "a "]]))
        XCTAssertFalse(mutation.matchesOriginal([["é", nil, "1", "a"]]))
        XCTAssertFalse(mutation.matchesOriginal([["é", nil, "1"]]))
    }

    func testReviewShowsOnlyEditsAndDistinguishesNullAndDefault() throws {
        let (draft, _) = fixture()
        draft.set(.null, row: 0, column: 2)
        draft.set(.text("new@example.test"), row: 0, column: 1)
        let row = try XCTUnwrap(draft.reviewChanges.first)
        XCTAssertEqual(row.identity, "id = 9007199254740993")
        XCTAssertEqual(row.fields.map(\.name), ["email", "name"])
        XCTAssertEqual(row.fields[0].before, .text("old@example.test"))
        XCTAssertEqual(row.fields[0].after, .text("new@example.test"))
        XCTAssertEqual(row.fields[1].before, .text("Before"))
        XCTAssertEqual(row.fields[1].after, .null)
        draft.set(.serverDefault, row: 1, column: 2)
        XCTAssertEqual(draft.reviewChanges[1].fields[0].before, .null)
        XCTAssertEqual(draft.reviewChanges[1].fields[0].after, .serverDefault)
        draft.deleteRow(0)
        XCTAssertTrue(draft.reviewChanges[0].fields.allSatisfy { $0.after == nil })
        draft.addRow()
        XCTAssertTrue(try XCTUnwrap(draft.reviewChanges.last).fields.allSatisfy { $0.before == nil })
    }

    func testSchemaCacheWithoutPrimaryKeyStillDecodes() throws {
        let (_, table) = fixture()
        let encoded = try JSONEncoder().encode(table)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "primaryKey")
        let old = try JSONDecoder().decode(SQLSchemaTable.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.primaryKey)
        XCTAssertEqual(old.editingKey(in: ["id"]), ["id"])
    }
}
