import Foundation
@testable import Krabzik
import XCTest

final class SQLClientListTests: XCTestCase {
    private func capture(_ values: [String?], type: UInt8 = 8, name: String = "ids") throws -> SQLClientList {
        var result = SQLResult(statement: 1, line: 1)
        result.columns = ["id"]
        result.origins = [.init(database: "", table: "", column: "id", mysqlType: type)]
        result.rows = values.map { [$0] }
        result.rowCount = values.count
        return try SQLClientList(name: name, results: [result], query: "SELECT id FROM sample", connectionName: "QA")
    }

    func testParsesOnlyOneReadQueryAndPreservesUnicodeAndComments() throws {
        let sql = "-- captura\nSET LIST ids = (SELECT id FROM `Organización` WHERE name = 'a);b')"
        let list = try XCTUnwrap(SQLListStatement.parse(sql))
        XCTAssertEqual(list.name, "ids")
        XCTAssertEqual(list.query, "SELECT id FROM `Organización` WHERE name = 'a);b'")
        XCTAssertNil(try SQLListStatement.parse("SET @ids = 1"))
        for query in ["SET LIST ids = SELECT 1", "SET LIST ids = (DELETE FROM t)", "SET LIST ids = (SELECT 1; SELECT 2)",
                      "SET LIST ids = (SELECT 1 INTO @x)", "SET LIST ids = (SELECT 1 FOR UPDATE)",
                      "SET LIST ids = (SELECT 1) + 2", "SET LIST ids = (SELECT /*!1*/ 1)"] {
            XCTAssertThrowsError(try SQLListStatement.parse(query), query)
        }
        XCTAssertEqual(SQLWriteGuard.effect(of: sql), .read)
        XCTAssertEqual(SQLWriteGuard.effect(of: "SET LIST ids = (SELECT 1 INTO OUTFILE '/tmp/a')"), .write)
    }

    func testTypedExpansionPreservesBigIntegersAndEscapesTextWithoutConvert() throws {
        let ids = try capture(["9007199254740993", "56", nil, "56"])
        XCTAssertEqual(ids.sql, "9007199254740993, 56")
        let text = try capture(["001", "O'Brien", "'); DELETE FROM t; --", "😀"], type: 253, name: "names")
        XCTAssertTrue(text.sql.hasPrefix("'001', 'O''Brien'"))
        XCTAssertFalse(text.sql.contains("CONVERT("))
        let sql = "SELECT * FROM t WHERE id IN ({{ids}}) AND name NOT IN ({{ names }})"
        let expanded = try SQLListStatement.expand(sql, lists: ["ids": ids, "names": text])
        XCTAssertTrue(expanded.contains("id IN (9007199254740993, 56)"))
        for mode in [false, true] {
            var cursor = SQLScript(expanded)
            XCTAssertNotNil(try cursor.next(noBackslashEscapes: mode))
            XCTAssertNil(try cursor.next(noBackslashEscapes: mode))
        }
    }

    func testTextListsCombineWithScalarsWithoutReinterpretingTheirContents() throws {
        let names = try capture(["JJ7QYT", "O'Brien", "001", "@PNR", "{{missing}}", "", "a\\b", "😀"],
                                type: 253, name: "pnrs")
        let ids = try capture(["3", "9007199254740993"])
        let query = "SELECT * FROM requests WHERE pnr IN ({{pnrs}}) AND id IN ({{ids}}) AND mor = @AIRLINE_ID AND pnr <> @PNR"
        for mode in [false, true] {
            let lists = try SQLListStatement.expand(query, lists: ["pnrs": names, "ids": ids], noBackslashEscapes: mode)
            let scalars = try SQLScalarExpansion(lists, noBackslashEscapes: mode)
            XCTAssertEqual(scalars.names, ["@AIRLINE_ID", "@PNR"])
            var result = SQLResult(statement: 0, line: 1)
            result.rows = [["3", "O'Brien"]]
            result.origins = [.init(database: "", table: "", column: "", mysqlType: 8),
                              .init(database: "", table: "", column: "", mysqlType: 253)]
            let expanded = try scalars.expand(result)
            XCTAssertEqual(expanded, "SELECT * FROM requests WHERE pnr IN "
                + "('JJ7QYT', 'O''Brien', '001', '@PNR', '{{missing}}', '', CONCAT('a', CHAR(92 USING utf8mb4), 'b'), '😀') "
                + "AND id IN (3, 9007199254740993) AND mor = 3 AND pnr <> 'O''Brien'")
            var script = SQLScript(expanded)
            XCTAssertNotNil(try script.next(noBackslashEscapes: mode))
            XCTAssertNil(try script.next(noBackslashEscapes: mode))
        }
    }

    func testCommentsStringsAndIdentifiersAreNeverExpandedAndInvalidReferencesFail() throws {
        let ids = try capture(["1"])
        let sql = "SELECT '{{missing}}', `{{other}}` FROM t WHERE id IN ({{ids}}) /* {{ignored}} */ -- {{comment}}"
        XCTAssertEqual(try SQLListStatement.expand(sql, lists: ["ids": ids]), sql.replacingOccurrences(of: "{{ids}}", with: "1"))
        XCTAssertThrowsError(try SQLListStatement.expand("SELECT * FROM t WHERE id IN ({{missing}})", lists: [:]))
        XCTAssertThrowsError(try SQLListStatement.expand("SELECT {{ids}}", lists: ["ids": ids]))
        XCTAssertThrowsError(try SQLListStatement.expand("SELECT * FROM t WHERE id IN ({{ids)", lists: ["ids": ids]))
        let empty = try capture([])
        XCTAssertThrowsError(try SQLListStatement.expand("SELECT * FROM t WHERE id IN ({{ids}})", lists: ["ids": empty]))
        XCTAssertThrowsError(try capture(["1); DROP TABLE t"], type: 8))
    }

    func testIncompleteMultipleColumnsAndBinaryResultsAreRejected() throws {
        var result = SQLResult(statement: 1, line: 1)
        result.columns = ["id"]
        result.rows = [["1"]]
        result.rowCount = 2
        XCTAssertThrowsError(try SQLClientList(name: "ids", results: [result], query: "SELECT id", connectionName: "QA"))
        result.rowCount = 1
        result.truncated = true
        XCTAssertThrowsError(try SQLClientList(name: "ids", results: [result], query: "SELECT id", connectionName: "QA"))
        result.truncated = false
        result.origins = [.init(database: "", table: "", column: "id", binary: true)]
        XCTAssertThrowsError(try SQLClientList(name: "ids", results: [result], query: "SELECT id", connectionName: "QA"))
        result.columns = ["a", "b"]
        XCTAssertThrowsError(try SQLClientList(name: "ids", results: [result], query: "SELECT 1,2", connectionName: "QA"))
    }

    @MainActor func testCompletionReplacesExistingClosingBracesAndIgnoresQuotedReferences() throws {
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/list-completion.sql"),
                                          data: Data("SELECT 1 WHERE id IN ({{org}})".utf8))
        let surface = EditorSurface(document: document)
        defer { surface.teardown() }
        surface.textView.sqlCompletionEnabled = true
        let range = (document.text as NSString).range(of: "org")
        surface.textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        XCTAssertEqual(surface.textView.rangeForUserCompletion, NSRange(location: range.location, length: range.length + 2))
        let database = DatabaseController()
        XCTAssertNil(database.listCompletions(text: "SELECT '{{org", position: 13))
        XCTAssertNil(database.listCompletions(text: "-- {{org", position: 8))
        XCTAssertEqual(database.listCompletions(text: "SELECT 1 WHERE id IN ({{org", position: 26), [])
    }

    func testStoreSeparatesProjectsAndReplacesNames() async throws {
        let store = SQLClientListStore()
        try await store.set(capture(["1"]), scope: "project-a")
        try await store.set(capture(["2"]), scope: "project-b")
        let first = await store.snapshot("project-a"), second = await store.snapshot("project-b")
        XCTAssertEqual(first["ids"]?.sql, "1")
        XCTAssertEqual(second["ids"]?.sql, "2")
        await store.remove("ids", scope: "project-a")
        let removed = await store.snapshot("project-a")
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(second["ids"]?.note.isList, true)
    }
}
