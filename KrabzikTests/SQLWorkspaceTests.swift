import AppKit
@testable import Krabzik
import XCTest

final class SQLWorkspaceTests: XCTestCase {
    func testCursorFindsWholeMultilineStatementAndIgnoresBlankLine() throws {
        let sql = "SELECT '🦀;';\n\nSELECT id,\n name\nFROM users;\nSELECT 3;"
        let range = (sql as NSString).range(of: "name")
        let statement = try SQLScript.atCursor(in: sql, selection: NSRange(location: range.location + 2, length: 0))
        XCTAssertEqual(statement?.text, "SELECT id,\n name\nFROM users")
        XCTAssertEqual(statement?.line, 3)
        let blank = (sql as NSString).range(of: "\n\n")
        XCTAssertNil(try SQLScript.atCursor(in: sql, selection: NSRange(location: blank.location + 1, length: 0)))
        let selected = (sql as NSString).range(of: "SELECT 3;")
        XCTAssertEqual(try SQLScript.atCursor(in: sql, selection: selected)?.text, "SELECT 3;")
    }

    func testCursorAfterSemicolonDoesNotRunNextStatement() throws {
        let sql = "SELECT 1;\nSELECT 2;"
        XCTAssertEqual(try SQLScript.atCursor(in: sql, selection: NSRange(location: 9, length: 0))?.text, "SELECT 1")
    }

    @MainActor func testCompletionReplacesOnlyColumnAndPreservesAlias() {
        let view = CodeTextView(usingTextLayoutManager: true)
        view.sqlCompletionEnabled = true
        view.string = "SELECT p.na FROM people p"
        view.setSelectedRange(NSRange(location: 11, length: 0))
        XCTAssertEqual(view.rangeForUserCompletion, NSRange(location: 9, length: 2))
    }

    @MainActor func testSuggestionWaitsForAcceptanceAndPreservesQualifiedName() throws {
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/completion.sql"),
                                          data: Data("SELECT p.na FROM people p".utf8))
        let surface = EditorSurface(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        surface.completion = { _, _ in ["name"] }
        surface.textView.sqlCompletionEnabled = true
        surface.textView.setSelectedRange(NSRange(location: 11, length: 0))
        surface.textView.complete(nil)
        XCTAssertEqual(surface.textView.string, "SELECT p.na FROM people p")
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                   charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        surface.textView.keyDown(with: enter)
        XCTAssertEqual(surface.textView.string, "SELECT p.name FROM people p")
        surface.teardown()
        window.contentView = nil
    }

    @MainActor func testRoutineAtCursorKeepsItsDelimiter() throws {
        let sql = "DELIMITER $$\nCREATE PROCEDURE p()\nBEGIN\n SELECT 1;\n SELECT 2;\nEND$$\nDELIMITER ;\nSELECT 3;"
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/routine.sql"), data: Data(sql.utf8))
        document.selectedRange = NSRange(location: (sql as NSString).range(of: "SELECT 2").location, length: 0)
        let query = try document.queryAtCursor()
        var parser = SQLScript(query.text, startingLine: query.startingLine)
        let statement = try parser.next()
        XCTAssertTrue(statement?.text.contains("SELECT 1;\n SELECT 2;") == true)
        XCTAssertEqual(statement?.line, 2)
        XCTAssertNil(try parser.next())
    }

    func testCursorDoesNotExecuteOtherQueryForInvalidOrCommentPosition() throws {
        for sql in ["", "\n", "-- SELECT 1\nSELECT 2;", "# comment\nSELECT 2;"] {
            XCTAssertNil(try SQLScript.atCursor(in: sql, selection: NSRange(location: 0, length: 0)))
        }
        XCTAssertNil(try SQLScript.atCursor(in: "SELECT 1", selection: NSRange(location: 99, length: 0)))
        XCTAssertThrowsError(try SQLScript.atCursor(in: "SELECT 'bad", selection: NSRange(location: 7, length: 0)))
    }

    @MainActor private func fixture() -> (SQLResult, SQLSchemaTable) {
        let table = SQLSchemaTable(database: "qa", name: "users", kind: "BASE TABLE", engine: "InnoDB", columns: [
            SQLSchemaColumn(name: "id", type: "int", nullable: false, extra: "auto_increment"),
            SQLSchemaColumn(name: "name", type: "varchar(60)", nullable: true, extra: "")
        ], uniqueKeys: [["id"]])
        var result = SQLResult(statement: 1, line: 1)
        result.sql = "SELECT id, name FROM users"
        result.columns = ["id", "name"]
        result.origins = result.columns.map { SQLColumnOrigin(database: "qa", table: "users", column: $0) }
        result.rows = [["1", "Before"], ["2", nil]]
        return (result, table)
    }

    @MainActor func testEditsAreStagedIndependentlyAndSQLDoesNotInterpolateText() throws {
        let (result, table) = fixture()
        let draft = SQLResultDraft(result: result)
        draft.configure(table)
        XCTAssertTrue(draft.canEdit)
        draft.set(.text("O'Reilly\\'; DROP TABLE users; -- 🦀"), row: 0, column: 1)
        XCTAssertEqual(result.rows[0][1], "Before")
        let mutations = try draft.mutations()
        XCTAssertEqual(mutations.count, 1)
        XCTAssertFalse(mutations[0].sql.contains("DROP TABLE"))
        XCTAssertTrue(mutations[0].sql.contains("CAST(`id` AS BINARY) <=>"))
        XCTAssertTrue(mutations[0].sql.hasSuffix("LIMIT 1"))
        draft.set(.null, row: 0, column: 0)
        XCTAssertEqual(draft.changes.count, 1)
        draft.set(.null, row: 0, column: 1)
        XCTAssertTrue(try draft.mutations()[0].sql.contains("`name` = NULL"))
        draft.set(.text("Before"), row: 0, column: 1)
        XCTAssertFalse(draft.hasChanges)
    }

    @MainActor func testInsertDuplicateDeleteAndUndoRespectMetadata() throws {
        let (result, table) = fixture()
        let draft = SQLResultDraft(result: result)
        draft.configure(table)
        draft.addRow(duplicating: 0)
        XCTAssertEqual(draft.value(row: 2, column: 0), .serverDefault)
        XCTAssertEqual(draft.value(row: 2, column: 1), .text("Before"))
        XCTAssertTrue(try draft.mutations()[0].sql.hasPrefix("INSERT INTO"))
        draft.deleteRow(2)
        XCTAssertFalse(draft.hasChanges)
        draft.deleteRow(0)
        XCTAssertTrue(try draft.mutations()[0].sql.hasPrefix("DELETE FROM"))
        draft.deleteRow(0)
        XCTAssertFalse(draft.hasChanges)
    }

    @MainActor func testAmbiguousTruncatedAndKeylessResultsAreReadOnly() {
        let (original, table) = fixture()
        var result = original
        result.truncated = true
        XCTAssertNotNil(SQLResultDraft.readOnlyReason(result, table: table))
        result = original
        result.rows.append(result.rows[0])
        XCTAssertNotNil(SQLResultDraft.readOnlyReason(result, table: table))
        result = original
        result.origins[1].table = "other"
        XCTAssertNotNil(SQLResultDraft.readOnlyReason(result, table: table))
        var keyless = table
        keyless.uniqueKeys = []
        XCTAssertNotNil(SQLResultDraft.readOnlyReason(original, table: keyless))
    }

    @MainActor func testSchemaCacheAndAliasCompletionKeepEndpointIdentity() throws {
        let name = "braket-schema-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SQLSchemaStore(defaults: defaults)
        let connection = DatabaseConnection()
        let (_, table) = fixture()
        store.snapshots[connection.id] = SQLSchemaSnapshot(connection: connection, databases: ["qa"], tables: [table])
        store.save(.init(visible: ["qa"], defaultDatabase: "qa"), for: connection)
        let sql = "SELECT u.na FROM users u"
        let position = (sql as NSString).range(of: "u.na").location + 4
        XCTAssertEqual(store.completions(connection: connection, database: "qa", text: sql, position: position), ["name"])
        XCTAssertEqual(SQLSchemaStore(defaults: defaults).preference(connection).defaultDatabase, "qa")
        var changed = connection
        changed.host = "elsewhere"
        XCTAssertNil(store.snapshot(changed))
    }

    private actor Sink {
        var values: [SQLResult] = []
        func append(_ result: SQLResult) { values.append(result) }
    }
    private static func run(_ sql: String, client: MySQLClient, config: DatabaseConnection) async throws -> [SQLResult] {
        let sink = Sink()
        _ = try await client.execute(sql, startingLine: 1, configuration: config, password: "", operation: UUID()) {
            await sink.append($0)
        }
        return await sink.values
    }

    @MainActor func testRealMetadataEditsNullDefaultsAndConflictRollback() async throws {
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mysql-test-port")
        guard let value = try? String(contentsOf: marker, encoding: .utf8),
              let port = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw XCTSkip("MySQL local requerido") }
        var config = DatabaseConnection()
        config.port = port
        config.database = "krabzik_qa"
        config.tls = .disabled
        let client = MySQLClient()
        do {
            _ = try await Self.run("""
            DROP TABLE IF EXISTS braket_edit_qa;
            CREATE TABLE braket_edit_qa(id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(80) NULL,
                status ENUM('new','done') NOT NULL DEFAULT 'new') ENGINE=InnoDB;
            INSERT INTO braket_edit_qa(name) VALUES ('one'),('two');
            """, client: client, config: config)
            let snapshot = try await client.schema(config, password: "", databases: ["krabzik_qa"])
            let table = try XCTUnwrap(snapshot.tables.first { $0.name == "braket_edit_qa" })
            XCTAssertEqual(table.uniqueKeys, [["id"]])
            XCTAssertEqual(table.columns[2].enumValues, ["new", "done"])
            let results = try await Self.run("SELECT * FROM braket_edit_qa ORDER BY id", client: client, config: config)
            let result = try XCTUnwrap(results.first)
            XCTAssertEqual(result.origins.map(\.column), ["id", "name", "status"])
            XCTAssertEqual(result.connection, config)
            let draft = SQLResultDraft(result: result)
            draft.configure(table)
            XCTAssertTrue(draft.canEdit, draft.reason)
            draft.set(.null, row: 0, column: 1)
            draft.set(.text("O'Reilly 🦀"), row: 1, column: 1)
            draft.addRow()
            draft.set(.text("three"), row: 2, column: 1)
            try await client.apply(draft.mutations(), table: table, configuration: config, password: "")
            let updated = try await Self.run("SELECT * FROM braket_edit_qa ORDER BY id", client: client, config: config)
            XCTAssertEqual(updated[0].rows, [["1", nil, "new"], ["2", "O'Reilly 🦀", "new"], ["3", "three", "new"]])
            let unchanged = SQLResultDraft(result: updated[0])
            unchanged.configure(table)
            unchanged.set(.serverDefault, row: 0, column: 2)
            try await client.apply(unchanged.mutations(), table: table, configuration: config, password: "")
            let conflicting = SQLResultDraft(result: updated[0])
            conflicting.configure(table)
            conflicting.set(.text("pending one"), row: 0, column: 1)
            conflicting.set(.text("pending two"), row: 1, column: 1)
            _ = try await Self.run("UPDATE braket_edit_qa SET name='external' WHERE id=2", client: client, config: config)
            do {
                try await client.apply(conflicting.mutations(), table: table, configuration: config, password: "")
                XCTFail("Must reject a changed row and roll back the first update")
            } catch { XCTAssertTrue(MySQLClient.message(error).contains("fila cambió")) }
            let retained = try await Self.run("SELECT name FROM braket_edit_qa ORDER BY id", client: client, config: config)
            XCTAssertEqual(retained[0].rows, [[nil], ["external"], ["three"]])
            XCTAssertTrue(conflicting.hasChanges)
            _ = try await Self.run("DROP TABLE braket_edit_qa", client: client, config: config)
        } catch { await client.shutdown()
        throw error }
        await client.shutdown()
    }
}
