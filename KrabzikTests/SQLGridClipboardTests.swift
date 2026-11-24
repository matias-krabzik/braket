import AppKit
@testable import Krabzik
import SwiftUI
import XCTest

@MainActor final class SQLGridClipboardTests: XCTestCase {
    private struct Grid {
        let draft: SQLResultDraft
        let table: SQLGridTable
        let window: NSWindow
        let board: NSPasteboard
        var coordinator: SQLResultGrid.Coordinator? { table.delegate as? SQLResultGrid.Coordinator }
        func close() {
            SQLCellEditorController.active?.cancelEditing()
            window.orderOut(nil)
            board.releaseGlobally()
        }
    }
    private func key(_ code: UInt16, text: String = "", flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
                                       isARepeat: false, keyCode: code))
    }
    private func find(_ view: NSView) -> SQLGridTable? {
        if let table = view as? SQLGridTable { return table }
        return view.subviews.lazy.compactMap { self.find($0) }.first
    }
    private func grid() async throws -> Grid {
        let columns = [
            SQLSchemaColumn(name: "id", type: "bigint unsigned", nullable: false, extra: "auto_increment"),
            SQLSchemaColumn(name: "text", type: "text", nullable: true, extra: ""),
            SQLSchemaColumn(name: "quantity", type: "tinyint", nullable: false, extra: ""),
            SQLSchemaColumn(name: "created", type: "datetime(6)", nullable: true, extra: ""),
            SQLSchemaColumn(name: "status", type: "enum('new','done')", nullable: false, defaultValue: "new", extra: ""),
            SQLSchemaColumn(name: "generated", type: "int", nullable: true, extra: "VIRTUAL GENERATED")
        ]
        let schema = SQLSchemaTable(database: "qa", name: "items", kind: "BASE TABLE", engine: "InnoDB", columns: columns,
                                    uniqueKeys: [["id"]], primaryKey: ["id"])
        var result = SQLResult(statement: 1, line: 1)
        result.sql = "SELECT * FROM items"
        result.columns = columns.map(\.name)
        result.origins = columns.map { SQLColumnOrigin(database: "qa", table: "items", column: $0.name) }
        result.rows = [["18446744073709551614", "one", "1", "2026-11-20 12:00:00.123456", "new", "2"],
                       ["2", nil, "2", nil, "done", "4"]]
        let draft = SQLResultDraft(result: result)
        draft.configure(schema)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SQLResultGrid(draft: draft, scale: 1, theme: .graphite))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let table = try XCTUnwrap(window.contentView.flatMap(find))
        let board = NSPasteboard.withUniqueName()
        table.pasteboard = board
        window.makeFirstResponder(table)
        return Grid(draft: draft, table: table, window: window, board: board)
    }
    private func text(_ text: String, to board: NSPasteboard) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func testCommandCopyAndPasteWorkFromKeyboardSelectionAndOnlyStageTheChange() async throws {
        let grid = try await grid()
        defer { grid.close() }
        grid.table.keyDown(with: try key(125))
        XCTAssertTrue(grid.table.performKeyEquivalent(with: try key(8, text: "c", flags: .command)))
        XCTAssertEqual(grid.board.string(forType: .string), "18446744073709551614")
        grid.table.keyDown(with: try key(124))
        text("  pasted\ntext\t😀  ", to: grid.board)
        grid.table.keyDown(with: try key(9, text: "v", flags: .command))
        XCTAssertEqual(grid.draft.value(row: 0, column: 1), .text("  pasted\ntext\t😀  "))
        XCTAssertEqual(grid.draft.result.rows[0][1], "one")
        XCTAssertTrue(grid.draft.hasChanges)
        XCTAssertFalse(grid.draft.sent)
        XCTAssertFalse(grid.draft.isEditingCell)
        grid.table.copy(nil)
        XCTAssertEqual(grid.board.string(forType: .string), "  pasted\ntext\t😀  ")
    }

    func testNativeMenuValidationAndReadOnlyCopyNeverAllowPasting() async throws {
        let grid = try await grid()
        defer { grid.close() }
        let copy = NSMenuItem(title: "Copiar", action: #selector(SQLGridTable.copy(_:)), keyEquivalent: "c")
        let paste = NSMenuItem(title: "Pegar", action: #selector(SQLGridTable.paste(_:)), keyEquivalent: "v")
        XCTAssertFalse(grid.table.validateUserInterfaceItem(copy))
        grid.coordinator?.select(row: 0, column: 1)
        XCTAssertTrue(grid.table.validateUserInterfaceItem(copy))
        XCTAssertFalse(grid.table.validateUserInterfaceItem(paste))
        text("new", to: grid.board)
        XCTAssertTrue(grid.table.validateUserInterfaceItem(paste))
        grid.draft.reason = "Solo lectura"
        XCTAssertFalse(grid.table.validateUserInterfaceItem(paste))
        grid.table.paste(nil)
        XCTAssertEqual(grid.draft.value(row: 0, column: 1), .text("one"))
        grid.table.copy(nil)
        XCTAssertEqual(grid.board.string(forType: .string), "one")
    }

    func testPastingHonorsNumericEnumDateGeneratedAndDeletedCellRules() async throws {
        let grid = try await grid()
        defer { grid.close() }
        for (column, invalid, valid) in [(2, "999", "127"), (3, "2026-02-30", "2026-11-20 01:02:03.123456"),
                                         (4, "not-an-enum", "done")] {
            grid.coordinator?.select(row: 0, column: column)
            let original = grid.draft.value(row: 0, column: column)
            text(invalid, to: grid.board)
            grid.table.paste(nil)
            XCTAssertEqual(grid.draft.value(row: 0, column: column), original)
            XCTAssertNotNil(grid.draft.error)
            text(valid, to: grid.board)
            grid.table.paste(nil)
            XCTAssertEqual(grid.draft.value(row: 0, column: column), .text(valid))
            XCTAssertNil(grid.draft.error)
        }
        grid.coordinator?.select(row: 0, column: 5)
        text("999", to: grid.board)
        XCTAssertFalse(grid.coordinator?.canPasteSelectedValue == true)
        grid.table.paste(nil)
        XCTAssertEqual(grid.draft.value(row: 0, column: 5), .text("2"))
        grid.coordinator?.select(row: 0, column: 1)
        grid.draft.deleted.insert(0)
        XCTAssertFalse(grid.coordinator?.canPasteSelectedValue == true)
    }

    func testNullDefaultEmptyTextAndLiteralNullStayDistinct() async throws {
        let grid = try await grid()
        defer { grid.close() }
        grid.coordinator?.select(row: 1, column: 1)
        grid.table.copy(nil)
        XCTAssertEqual(SQLCellClipboard.read(from: grid.board), .null)
        grid.coordinator?.select(row: 0, column: 1)
        grid.table.paste(nil)
        XCTAssertEqual(grid.draft.value(row: 0, column: 1), .null)
        text("NULL", to: grid.board)
        grid.table.paste(nil)
        XCTAssertEqual(grid.draft.value(row: 0, column: 1), .text("NULL"))
        text("", to: grid.board)
        grid.table.paste(nil)
        XCTAssertEqual(grid.draft.value(row: 0, column: 1), .text(""))
        grid.coordinator?.select(row: 0, column: 2)
        SQLCellClipboard.write(.null, to: grid.board)
        grid.table.paste(nil)
        XCTAssertEqual(grid.draft.value(row: 0, column: 2), .text("1"))
        grid.coordinator?.select(row: 0, column: 4)
        SQLCellClipboard.write(.serverDefault, to: grid.board)
        grid.table.paste(nil)
        XCTAssertEqual(grid.draft.value(row: 0, column: 4), .serverDefault)
    }

    func testClipboardInInlineTextEditorActsOnItsTextAndKeepsEnterToConfirm() async throws {
        let grid = try await grid()
        defer { grid.close() }
        grid.coordinator?.select(row: 0, column: 1)
        grid.table.keyDown(with: try key(36))
        let editor = try XCTUnwrap(SQLCellEditorController.active)
        editor.textView.setSelectedRange(NSRange(location: 1, length: 1))
        SQLCellClipboard.write(.null, to: grid.board)
        XCTAssertTrue(grid.table.performKeyEquivalent(with: try key(8, text: "c", flags: .command)))
        XCTAssertTrue(editor.textView.performKeyEquivalent(with: try key(8, text: "c", flags: .command)))
        XCTAssertEqual(grid.board.string(forType: .string), "n")
        XCTAssertNil(grid.board.string(forType: SQLCellClipboard.valueType))
        editor.textView.setSelectedRange(NSRange(location: 0, length: editor.textView.string.utf16.count))
        text("new\nline", to: grid.board)
        XCTAssertTrue(editor.textView.performKeyEquivalent(with: try key(9, text: "v", flags: .command)))
        XCTAssertEqual(editor.textView.string, "new\nline")
        XCTAssertEqual(grid.draft.value(row: 0, column: 1), .text("one"))
        editor.textView.keyDown(with: try key(36))
        XCTAssertEqual(grid.draft.value(row: 0, column: 1), .text("new\nline"))
        XCTAssertFalse(grid.draft.isEditingCell)
    }

    func testNumericInlinePasteStillUsesTypeValidationAndDoesNotEscapeToTheGrid() async throws {
        let grid = try await grid()
        defer { grid.close() }
        grid.coordinator?.select(row: 0, column: 2)
        grid.table.keyDown(with: try key(36))
        let editor = try XCTUnwrap(SQLCellEditorController.active)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 1))
        text("abc", to: grid.board)
        XCTAssertTrue(editor.textView.performKeyEquivalent(with: try key(9, text: "v", flags: .command)))
        XCTAssertEqual(editor.textView.string, "1")
        XCTAssertFalse(editor.errorLabel.isHidden)
        XCTAssertEqual(grid.draft.value(row: 0, column: 2), .text("1"))
    }
}
