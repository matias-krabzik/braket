import AppKit
@testable import Krabzik
import XCTest

final class SQLWorkspaceTests: XCTestCase {
    func testSetReadbackOnlyUsesAssignmentTargets() throws {
        let set = try XCTUnwrap(SQLSetStatement("-- inicio\nSET @limite := 10, @total = COALESCE(5, 2) * 2, "
                                               + "@nombre = 'a,b=otro', @@SESSION.sql_mode = 'ANSI'"))
        XCTAssertEqual(set.targets.map(\.label), ["@limite", "@total", "@nombre", "sql_mode"])
        XCTAssertEqual(set.targets.map(\.expression), ["@limite", "@total", "@nombre", "@@SESSION.`sql_mode`"])
        XCTAssertFalse(try XCTUnwrap(set.query).contains("COALESCE"))
        XCTAssertNil(SQLSetStatement("SELECT 'SET @x = 1'"))
        XCTAssertNil(SQLSetStatement("UPDATE t SET x = 1"))
        XCTAssertEqual(SQLSetStatement("SET GLOBAL max_connections = 100")?.targets.first?.expression,
                       "@@GLOBAL.`max_connections`")
        XCTAssertEqual(SQLSetStatement("SET NAMES utf8mb4")?.targets.count, 3)
        XCTAssertTrue(SQLSetStatement("SET PASSWORD = 'secret'")?.targets.isEmpty == true)
        XCTAssertTrue(SQLSetStatement("SET @x = 1 /*! + 1 */")?.targets.isEmpty == true)
        XCTAssertEqual(SQLSetStatement("SET @`a,b` = 'x'")?.targets.first?.expression, "@`a,b`")
    }

    @MainActor func testSetNotesDoNotAlterResultsOrDocumentTextAndExpireOnEdit() throws {
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/variables.sql"), data: Data("SET @n = 10;".utf8))
        let connection = DatabaseConnection()
        var set = SQLResult(statement: 1, line: 1)
        set.connection = connection
        set.sql = document.text
        set.setValues = [SQLSetValue(name: "@n", value: "10")]
        let execution = document.sqlExecution
        var select = SQLResult(statement: 1, line: 2)
        select.sql = "SELECT 1"
        select.rows = [["1"]]
        execution.receive(select)
        let selected = execution.selectedResultID
        XCTAssertTrue(execution.begin(set))
        execution.receive(set)
        document.setVariableNote(set, revision: document.queryMarkerRevision)
        XCTAssertEqual(execution.results.count, 1)
        XCTAssertEqual(execution.selectedResultID, selected)
        XCTAssertEqual(document.setNotes[1]?.values, set.setValues)
        XCTAssertEqual(document.text, "SET @n = 10;")
        let revision = document.queryMarkerRevision
        document.text = "SET @n = 20;"
        XCTAssertTrue(document.setNotes.isEmpty)
        document.setVariableNote(set, revision: revision)
        XCTAssertTrue(document.setNotes.isEmpty)
    }

    @MainActor func testRepeatedQueryReusesTabAndReplacesData() {
        let execution = SQLExecution()
        var result = SQLResult(statement: 1, line: 1)
        result.sql = "SELECT id FROM people"
        result.connection = DatabaseConnection()
        result.database = "qa"
        XCTAssertTrue(execution.begin(result))
        let id = execution.selectedResultID
        XCTAssertEqual(execution.selectedResult?.isLoading, true)
        result.columns = ["id"]
        result.rows = [["1"]]
        execution.receive(result)
        XCTAssertEqual(execution.selectedResultID, id)
        XCTAssertTrue(execution.begin(result))
        result.rows = [["2"]]
        execution.receive(result)
        XCTAssertEqual(execution.results.count, 1)
        XCTAssertEqual(execution.selectedResultID, id)
        XCTAssertEqual(execution.selectedResult?.rows, [["2"]])
        result.database = "other"
        execution.receive(result)
        XCTAssertEqual(execution.results.count, 2)
        result.resultIndex = 1
        execution.receive(result)
        XCTAssertEqual(execution.results.count, 3)
    }

    @MainActor func testFailedQueryLeavesRetryableTabWithoutSpinner() {
        let execution = SQLExecution()
        XCTAssertEqual(execution.timeoutSeconds, 15)
        var result = SQLResult(statement: 1, line: 1)
        result.sql = "SELECT SLEEP(20)"
        XCTAssertTrue(execution.begin(result))
        execution.finish(error: "Timeout")
        XCTAssertEqual(execution.selectedResult?.isLoading, false)
        XCTAssertEqual(execution.selectedResult?.error, "Timeout")
        XCTAssertEqual(execution.selectedResult?.sql, result.sql)
    }

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

    @MainActor func testSQLKeywordsCompleteWithoutConnection() {
        let store = SQLSchemaStore()
        XCTAssertTrue(store.completions(connection: nil, database: "", text: "sel", position: 3).contains("SELECT"))
        XCTAssertFalse(store.completions(connection: nil, database: "", text: "t.sel", position: 5).contains("SELECT"))
    }

    @MainActor func testBacktabRemovesOneIndentFromSelectedLines() {
        let view = CodeTextView(usingTextLayoutManager: true)
        view.string = "    SELECT\n\tFROM\n  WHERE\n    untouched"
        let length = ("    SELECT\n\tFROM\n  WHERE\n" as NSString).length
        view.setSelectedRange(NSRange(location: 0, length: length))
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "SELECT\nFROM\nWHERE\n    untouched")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: length - 7))
        view.setSelectedRange(NSRange(location: ("SELECT\nFROM\nWHERE\n  " as NSString).length, length: 0))
        view.insertBacktab(nil)
        XCTAssertEqual(view.string, "SELECT\nFROM\nWHERE\nuntouched")
        XCTAssertEqual(view.selectedRange().location, ("SELECT\nFROM\nWHERE\n" as NSString).length)
    }

    @MainActor func testSQLDeleteBackwardStopsAtLineAndJoinsIndentation() {
        let view = CodeTextView(usingTextLayoutManager: true)
        view.sqlCompletionEnabled = true
        view.string = "SELECT id\n    FROM users"
        view.setSelectedRange(NSRange(location: 18, length: 0))
        view.deleteWordBackward(nil)
        XCTAssertEqual(view.string, "SELECT id\n users")
        view.string = "SELECT id  \n\t  FROM users"
        view.setSelectedRange(NSRange(location: 15, length: 0))
        view.deleteWordBackward(nil)
        XCTAssertEqual(view.string, "SELECT id FROM users")
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

    func testPaginationRecognizesOuterLimitAndSkipsWrites() throws {
        XCTAssertNil(SQLPagination("SELECT * FROM t LIMIT 9", page: 0))
        XCTAssertNil(SQLPagination("UPDATE t SET x = 1", page: 0))
        XCTAssertNil(SQLPagination("DELETE FROM t", page: 0))
        XCTAssertNil(SQLPagination("SELECT * INTO OUTFILE 'x' FROM t", page: 0))
        let page = try XCTUnwrap(SQLPagination("SELECT 'LIMIT 9', `limit` FROM (SELECT * FROM t LIMIT 2) q -- LIMIT 3", page: 2))
        XCTAssertTrue(page.query.contains("LIMIT 101 OFFSET 200"))
        XCTAssertNotNil(page.countQuery)
        let cte = try XCTUnwrap(SQLPagination("WITH q AS (SELECT * FROM t LIMIT 8) SELECT * FROM q", page: 0))
        XCTAssertTrue(cte.query.contains("LIMIT 101 OFFSET 0"))
        let locked = try XCTUnwrap(SQLPagination("SELECT * FROM t FOR UPDATE", page: 0))
        XCTAssertTrue(locked.query.contains("LIMIT 101 OFFSET 0\nFOR UPDATE"))
        XCTAssertNil(locked.countQuery)
    }

    @MainActor func testPinnedResultSurvivesIdenticalQueryAndExplicitPagingKeepsPin() throws {
        let execution = SQLExecution()
        var result = SQLResult(statement: 1, line: 1)
        result.sql = "SELECT * FROM t"
        XCTAssertTrue(execution.begin(result))
        result.rows = [["original"]]
        execution.receive(result)
        let pinned = try XCTUnwrap(execution.selectedResultID)
        execution.pinned.insert(pinned)
        XCTAssertTrue(execution.begin(result))
        result.rows = [["new"]]
        execution.receive(result)
        XCTAssertEqual(execution.results.count, 2)
        XCTAssertEqual(execution.results.first?.rows, [["original"]])
        XCTAssertNotEqual(execution.selectedResultID, pinned)
        execution.targetResultID = pinned
        XCTAssertTrue(execution.begin(result))
        result.page = SQLPage(index: 1, totalRows: 150, hasNext: false)
        execution.receive(result)
        XCTAssertEqual(execution.results.count, 2)
        XCTAssertEqual(execution.selectedResultID, pinned)
        XCTAssertTrue(execution.pinned.contains(pinned))
    }

    @MainActor func testResetOnlyChangesSelectedCommittedField() {
        let (result, table) = fixture()
        let draft = SQLResultDraft(result: result)
        draft.configure(table)
        draft.selectedCell = SQLCell(row: 0, column: 1)
        XCTAssertFalse(draft.canResetSelected)
        draft.set(.text("Changed"), row: 0, column: 1)
        draft.set(.text("Other"), row: 1, column: 1)
        draft.isEditingCell = true
        XCTAssertFalse(draft.canResetSelected)
        draft.isEditingCell = false
        XCTAssertTrue(draft.canResetSelected)
        draft.resetSelected()
        XCTAssertEqual(draft.value(row: 0, column: 1), .text("Before"))
        XCTAssertEqual(draft.value(row: 1, column: 1), .text("Other"))
        XCTAssertFalse(draft.canResetSelected)
        draft.sent = true
        draft.selectedCell = SQLCell(row: 1, column: 1)
        XCTAssertFalse(draft.canResetSelected)
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
        XCTAssertTrue(mutations[0].sql.contains("WHERE `id` = 1 LIMIT 1"))
        XCTAssertFalse(mutations[0].sql.contains("CAST("))
        XCTAssertEqual(mutations[0].originalRow, result.rows[0])
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

    @MainActor func testRealPrimaryKeyIndexAndUntouchedFieldConflict() async throws {
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
            CREATE TABLE braket_pk_qa (
                id BIGINT UNSIGNED PRIMARY KEY,
                email VARCHAR(80) NOT NULL,
                name VARCHAR(60), status INT NOT NULL DEFAULT 0,
                amount DECIMAL(18,4) DEFAULT 12.3400,
                a_date DATETIME DEFAULT '2020-01-02 03:04:05',
                UNIQUE KEY A_EMAIL (email)
            ) ENGINE=InnoDB;
            INSERT INTO braket_pk_qa(id,email,name) VALUES
                (9007199254740993,'one@example.test','one'),(9007199254740994,'two@example.test','two');
            """, client: client, config: config)
            let snapshot = try await client.schema(config, password: "", databases: ["krabzik_qa"])
            let table = try XCTUnwrap(snapshot.tables.first { $0.name == "braket_pk_qa" })
            XCTAssertEqual(table.primaryKey, ["id"])
            XCTAssertEqual(table.uniqueKeys.first, ["email"], "La PK debe ganar aunque otra clave aparezca primero")
            let fetched = try await Self.run("SELECT * FROM braket_pk_qa ORDER BY id", client: client, config: config)
            let draft = SQLResultDraft(result: try XCTUnwrap(fetched.first))
            draft.configure(table)
            draft.set(.text("pending one"), row: 0, column: 2)
            draft.set(.text("pending two"), row: 1, column: 2)
            let mutations = try draft.mutations()
            let verification = try XCTUnwrap(mutations.first?.verificationSQL)
            XCTAssertTrue(verification.contains("WHERE `id` = 9007199254740993"))
            let explained = try await Self.run("EXPLAIN " + verification, client: client, config: config)
            let explain = try XCTUnwrap(explained.first)
            let key = try XCTUnwrap(explain.columns.firstIndex(of: "key"))
            XCTAssertEqual(explain.rows.first?[key], "PRIMARY")
            _ = try await Self.run("UPDATE braket_pk_qa SET status=1 WHERE id=9007199254740994", client: client, config: config)
            do {
                try await client.apply(mutations, table: table, configuration: config, password: "")
                XCTFail("Un campo que no editamos cambió: debe revertirse todo")
            } catch { XCTAssertTrue(MySQLClient.message(error).contains("fila cambió")) }
            let retained = try await Self.run("SELECT name,status FROM braket_pk_qa ORDER BY id", client: client, config: config)
            XCTAssertEqual(retained.first?.rows, [["one", "0"], ["two", "1"]])
            let refreshed = try await Self.run("SELECT * FROM braket_pk_qa ORDER BY id", client: client, config: config)
            let latest = SQLResultDraft(result: try XCTUnwrap(refreshed.first))
            latest.configure(table)
            latest.set(.text("10"), row: 0, column: 0)
            latest.set(.null, row: 0, column: 2)
            latest.deleteRow(1)
            try await client.apply(latest.mutations(), table: table, configuration: config, password: "")
            let saved = try await Self.run("SELECT id,name,status,amount,a_date FROM braket_pk_qa", client: client, config: config)
            XCTAssertEqual(saved.first?.rows, [["10", nil, "0", "12.3400", "2020-01-02 03:04:05"]])
            _ = try await Self.run("DROP TABLE braket_pk_qa", client: client, config: config)
        } catch { await client.shutdown()
        throw error }
        await client.shutdown()
    }

    @MainActor func testServerNowUsesExistingSessionTimeZoneAndColumnType() async throws {
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mysql-test-port")
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
              let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw XCTSkip("MySQL local requerido") }
        var config = DatabaseConnection()
        config.port = port
        config.database = "krabzik_qa"
        config.tls = .disabled
        let client = MySQLClient()
        do {
            _ = try await Self.run("SET time_zone = '+09:00'; SET timestamp = 1234567890; START TRANSACTION; SAVEPOINT braket_clock;",
                                   client: client, config: config)
            let examples = ["date": "2009-02-14", "datetime": "2009-02-14 08:31:30",
                            "datetime(6)": "2009-02-14 08:31:30.000000", "timestamp(3)": "2009-02-14 08:31:30.000",
                            "time": "08:31:30", "time(3)": "08:31:30.000", "year": "2009"]
            for type in examples.keys.sorted() {
                let column = SQLSchemaColumn(name: "value", type: type, nullable: true, extra: "")
                let actual = try await client.serverNow(column: column, configuration: config)
                XCTAssertEqual(actual, examples[type], type)
            }
            let session = try await Self.run("SELECT @@session.time_zone, @@timestamp", client: client, config: config)
            XCTAssertEqual(session.first?.rows.first?[0], "+09:00")
            _ = try await Self.run("ROLLBACK TO SAVEPOINT braket_clock", client: client, config: config)
            let info = try await client.connect(config, password: "")
            XCTAssertTrue(info.inTransaction, "Ahora no debe confirmar ni cerrar la transacción del script")
            _ = try await Self.run("ROLLBACK; SET time_zone = '-04:00'", client: client, config: config)
            let column = SQLSchemaColumn(name: "value", type: "datetime", nullable: true, extra: "")
            let shifted = try await client.serverNow(column: column, configuration: config)
            XCTAssertEqual(shifted, "2009-02-13 19:31:30")
            await client.disconnect(config.id)
            do {
                _ = try await client.serverNow(column: column, configuration: config)
                XCTFail("Ahora no debe abrir otra sesión que pierda la zona horaria configurada")
            } catch { XCTAssertTrue(MySQLClient.message(error).contains("desconectada")) }
        } catch { await client.shutdown()
        throw error }
        await client.shutdown()
    }

    private func policy(_ name: String, _ level: DatabaseConnection.WritePolicy) -> DatabaseConnection {
        var connection = DatabaseConnection(name: name)
        connection.writePolicy = level.rawValue
        return connection
    }

    /// La `Task` de `execute` hereda el main actor: cancelarla sin ceder el hilo garantiza
    /// que no llegue a leer el llavero ni a abrir una conexión. Lo que se comprueba es que
    /// la guarda la dejó arrancar.
    @MainActor private func cancelBeforeItRuns(_ execution: SQLExecution) async {
        let task = execution.task
        task?.cancel()
        await task?.value
    }

    @MainActor func testReadOnlyProfileRejectsAWriteWithoutOpeningAConnection() async throws {
        let database = DatabaseController()
        let connection = policy("Ventas (producción)", .readOnly)
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/solo-lectura.sql"),
                                          data: Data("SELECT 1".utf8))
        let execution = document.sqlExecution
        database.execute(document, connection: connection, queryOverride: "UPDATE users SET name = 'x'")
        XCTAssertFalse(execution.isRunning)
        XCTAssertNil(execution.task)
        XCTAssertTrue(execution.results.isEmpty)
        let error = execution.error ?? ""
        XCTAssertEqual(document.queryMarkers[1]?.status, .failure)
        XCTAssertTrue(error.contains("Ventas (producción)"), error)
        XCTAssertTrue(error.contains("solo lectura"), error)
        XCTAssertTrue(error.contains("No se abrió ninguna conexión"), error)
        XCTAssertTrue(error.contains("UPDATE users"), error)
        XCTAssertEqual(database.state(connection.id).status, .disconnected)
        XCTAssertFalse(database.state(connection.id).busy)
        let session = await database.client.info(connection.id)
        XCTAssertNil(session)
    }

    @MainActor func testWriteGuardCountsEveryStatementOfTheScriptBeforeRejecting() throws {
        let database = DatabaseController()
        let connection = policy("Producción", .readOnly)
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/mixto.sql"), data: Data("SELECT 1".utf8))
        let script = "SELECT 1;\nUPDATE a SET b = 1;\nSELECT 2;\nDROP TABLE c;"
        database.execute(document, connection: connection, queryOverride: script)
        XCTAssertTrue(document.sqlExecution.error?.contains("2 de 4 sentencias escriben") == true,
                      document.sqlExecution.error ?? "")
        // Un script que no se puede partir se rechaza con el motivo, sin conectar.
        database.execute(document, connection: connection, queryOverride: "SELECT 'sin cerrar")
        XCTAssertNotNil(document.sqlExecution.error)
        XCTAssertNil(document.sqlExecution.task)
    }

    @MainActor func testReadOnlyLetsReadsThroughAndUnrestrictedIsNotClassified() async throws {
        let database = DatabaseController()
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/lectura.sql"), data: Data("SELECT 1".utf8))
        let execution = document.sqlExecution
        database.execute(document, connection: policy("Reportes", .readOnly), queryOverride: "SELECT * FROM users")
        XCTAssertTrue(execution.isRunning)
        XCTAssertEqual(document.queryMarkers[1]?.status, .loading)
        XCTAssertNil(execution.error)
        await cancelBeforeItRuns(execution)
        // Sin restricciones: una escritura arranca igual que antes de que existiera la guarda.
        let unrestricted = DatabaseConnection(name: "Local")
        XCTAssertNil(unrestricted.writePolicy)
        XCTAssertEqual(unrestricted.effectiveWritePolicy, .unrestricted)
        execution.error = nil
        database.execute(document, connection: unrestricted, queryOverride: "DELETE FROM users")
        XCTAssertTrue(execution.isRunning)
        XCTAssertNil(execution.error)
        await cancelBeforeItRuns(execution)
    }

    @MainActor func testEditingSQLClearsQueryMarkersAndIgnoresLateResults() throws {
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/consulta-marcadores.sql"),
                                          data: Data("SELECT 1;".utf8))
        let revision = document.queryMarkerRevision
        document.setQueryMarker(.loading, line: 1, revision: revision)
        XCTAssertEqual(document.queryMarkers[1]?.status, .loading)
        document.markTextStale()
        XCTAssertTrue(document.queryMarkers.isEmpty)
        document.setQueryMarker(.success, line: 1, revision: revision)
        XCTAssertTrue(document.queryMarkers.isEmpty)
    }

    @MainActor func testReadOnlyProfileBlocksGridEditingAndSubmitting() throws {
        let (original, table) = fixture()
        var result = original
        result.connection = policy("Producción", .readOnly)
        let reason = SQLResultDraft.readOnlyReason(result, table: table)
        XCTAssertEqual(reason, "Solo lectura: el perfil «Producción» no permite escrituras.")
        let draft = SQLResultDraft(result: result)
        draft.configure(table)
        XCTAssertFalse(draft.canEdit)
        XCTAssertFalse(draft.canInsert)
        draft.set(.text("Changed"), row: 0, column: 1)
        XCTAssertFalse(draft.hasChanges)
        let database = DatabaseController()
        database.submit(draft, profiles: [try XCTUnwrap(result.connection)])
        XCTAssertEqual(draft.error, "El perfil «Producción» está en solo lectura: no se envían cambios.")
        XCTAssertFalse(draft.sending)
        // Con `confirm` la grilla sigue editable: su hoja de revisión ya pregunta.
        var confirming = original
        confirming.connection = policy("Staging", .confirm)
        XCTAssertNil(SQLResultDraft.readOnlyReason(confirming, table: table))
    }

    @MainActor func testConfirmProfileAsksOncePerExecutionAndObeysTheAnswer() async throws {
        let database = DatabaseController()
        let connection = policy("Staging", .confirm)
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/confirmar.sql"), data: Data("SELECT 1".utf8))
        let execution = document.sqlExecution
        var asked: [Int] = []
        var answer = false
        database.askBeforeWriting = { audit, profile, destination in
            asked.append(audit.writes.count)
            XCTAssertEqual(profile.name, "Staging")
            XCTAssertFalse(destination.isEmpty)
            return answer
        }
        // Una lectura no pregunta nada.
        database.execute(document, connection: connection, queryOverride: "SELECT * FROM users")
        XCTAssertTrue(asked.isEmpty)
        await cancelBeforeItRuns(execution)
        // Dice que no: no arranca y no se abre ninguna conexión.
        database.execute(document, connection: connection, queryOverride: "DELETE FROM users; UPDATE users SET a = 1")
        XCTAssertEqual(asked, [2])
        XCTAssertFalse(execution.isRunning)
        XCTAssertNil(execution.task)
        let session = await database.client.info(connection.id)
        XCTAssertNil(session)
        // Dice que sí: arranca. Y la próxima ejecución vuelve a preguntar: la respuesta no
        // se recuerda ni para la próxima ni para el resto de la sesión.
        answer = true
        database.execute(document, connection: connection, queryOverride: "DELETE FROM users")
        XCTAssertEqual(asked, [2, 1])
        XCTAssertTrue(execution.isRunning)
        await cancelBeforeItRuns(execution)
        execution.error = nil
        database.execute(document, connection: connection, queryOverride: "DELETE FROM users")
        XCTAssertEqual(asked, [2, 1, 1])
        await cancelBeforeItRuns(execution)
    }

    @MainActor func testWriteAlertNamesTheDestinationAndDoesNotDefaultToTheDestructiveButton() throws {
        let audit = try SQLWriteGuard.audit("""
        DELETE FROM users WHERE id = 1;
        UPDATE users SET name = 'x';
        DROP TABLE viejos;
        TRUNCATE TABLE registros;
        SELECT 1;
        """)
        let connection = policy("Ventas (producción)", .confirm)
        let alert = DatabaseController.writeAlert(audit, connection: connection, destination: "db.ejemplo.com:3306 / ventas")
        XCTAssertEqual(alert.messageText, "¿Ejecutar 4 sentencias que escriben?")
        XCTAssertTrue(alert.informativeText.contains("Ventas (producción) · db.ejemplo.com:3306 / ventas"),
                      alert.informativeText)
        XCTAssertTrue(alert.informativeText.contains("5 sentencias en total"), alert.informativeText)
        XCTAssertTrue(alert.informativeText.contains("Línea 1: DELETE FROM users WHERE id = 1"), alert.informativeText)
        XCTAssertTrue(alert.informativeText.contains("Línea 3: DROP TABLE viejos"), alert.informativeText)
        XCTAssertFalse(alert.informativeText.contains("TRUNCATE"), alert.informativeText)
        XCTAssertTrue(alert.informativeText.hasSuffix("… y 1 más."), alert.informativeText)
        XCTAssertEqual(alert.buttons.count, 2)
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
        // ⏎ cancela: el botón destructivo no es el predeterminado.
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
    }
}
