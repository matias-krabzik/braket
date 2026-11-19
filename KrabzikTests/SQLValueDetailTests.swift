import AppKit
@testable import Krabzik
import XCTest

final class SQLValueDetailTests: XCTestCase {
    private func list(_ values: [String], type: UInt8 = 8) throws -> SQLClientList {
        var result = SQLResult(statement: 1, line: 1)
        result.columns = ["id"]
        result.origins = [.init(database: "qa", table: "demo", column: "id", mysqlType: type)]
        result.rows = values.map { [$0] }
        result.rowCount = values.count
        return try SQLClientList(name: "organizaciones", results: [result], query: "SELECT id FROM demo", connectionName: "QA")
    }

    func testPillCopyUsesTheFullReferenceAndTypedValues() throws {
        let numbers = try list(["9007199254740993", "56", "7"]).note
        XCTAssertEqual(numbers.clipboardReference, "{{organizaciones}}")
        XCTAssertEqual(numbers.clipboardValues, "9007199254740993, 56, 7")
        let strings = try list(["001", "O'Brien", "😀"], type: 253).note
        XCTAssertEqual(strings.clipboardValues, "'001', 'O''Brien', '😀'")
        let scalar = SQLSetValue(name: "@limite", value: "10")
        XCTAssertEqual(scalar.clipboardReference, "@limite")
        XCTAssertEqual(scalar.clipboardValues, "10")
        let system = SQLSetValue(name: "sql_mode", value: "STRICT_TRANS_TABLES", reference: "@@SESSION.`sql_mode`")
        XCTAssertEqual(system.clipboardReference, "@@SESSION.`sql_mode`")
        XCTAssertNil(SQLSetValue(name: "SET", value: "Aplicado").clipboardReference)
        XCTAssertNil(try list([]).note.clipboardValues)
    }

    @MainActor func testCopyButtonsDoNotEditSQLMoveCaretOrOpenTheCard() throws {
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/pill-copy.sql"), data: Data("SELECT 1;".utf8))
        let surface = EditorSurface(document: document)
        defer { surface.teardown() }
        let selection = NSRange(location: 2, length: 3)
        surface.textView.setSelectedRange(selection)
        var copied: [String] = []
        surface.textView.writeValueClipboard = { copied.append($0) }
        let value = try list(["1", "56", "7"]).note
        let rect = NSRect(x: 10, y: 10, width: 260, height: 20)
        XCTAssertTrue(surface.textView.performValuePillAction(.copyReference, value: value, rect: rect))
        XCTAssertTrue(surface.textView.performValuePillAction(.copyValues, value: value, rect: rect))
        XCTAssertEqual(copied, ["{{organizaciones}}", "1, 56, 7"])
        XCTAssertEqual(surface.textView.string, "SELECT 1;")
        XCTAssertEqual(surface.textView.selectedRange(), selection)
        XCTAssertNil(surface.textView.valueDetailPopover)
        XCTAssertFalse(surface.textView.performValuePillAction(.copyValues, value: try list([]).note, rect: rect))
        XCTAssertEqual(copied.count, 2, "Una lista vacía no borra el portapapeles")
        let hit = SQLValuePillHit(rect: rect, value: value, copyWidth: 20)
        let left = hit.frame(for: .copyReference), center = hit.frame(for: .detail), right = hit.frame(for: .copyValues)
        XCTAssertEqual(left.maxX, center.minX)
        XCTAssertEqual(center.maxX, right.minX)
        XCTAssertEqual(right.maxX, rect.maxX)
    }

    func testPillCarriesAllValuesAndKeepsItsCaptureAfterReplacement() throws {
        let original = try list((1...200).map(String.init))
        let pill = original.note
        let replacement = try list(["999"])
        let detail = SQLValueDetail(pill)
        XCTAssertEqual(detail.title, "organizaciones")
        XCTAssertEqual(detail.rows.count, 200, "El detalle no está limitado a los 10 valores del tooltip")
        XCTAssertEqual(detail.rows.last?.value, "200")
        XCTAssertEqual(replacement.values.count, 1)
        XCTAssertTrue(detail.subtitle.contains("Número"))
        XCTAssertEqual(detail.filtered("56").map(\.index), [56, 156])
        XCTAssertEqual(SQLValueDetail.copyText(detail.filtered("56")), "56, 156")
        XCTAssertNil(SQLValueDetail.copyText(detail.filtered("sin coincidencias")))
    }

    func testTextCopyPreservesQuotesUnicodeAndLineBreaksAsSQL() throws {
        let original = try list(["001", "O'Brien", "José 😀", "line 1\nline 2", "a\\b"], type: 253)
        let detail = SQLValueDetail(original.note)
        XCTAssertEqual(detail.rows.map(\.value), ["001", "O'Brien", "José 😀", "line 1\nline 2", "a\\b"])
        XCTAssertEqual(SQLValueDetail.copyText(detail.rows), original.sql)
        XCTAssertTrue(detail.subtitle.contains("Texto"))
        XCTAssertEqual(detail.filtered("jose").first?.value, "José 😀")
        let scalar = SQLValueDetail(SQLSetValue(name: "@limite", value: "10"))
        XCTAssertEqual(SQLValueDetail.copyText(scalar.rows), "10")
        XCTAssertEqual(scalar.title, "@limite")
        XCTAssertTrue(SQLValueDetail(SQLSetValue(name: "{{old}}", value: "500 valores", isList: true)).rows.isEmpty)
    }

    @MainActor func testSearchCopyEmptyStateAndEscapeWithoutTouchingSystemClipboard() throws {
        let card = SQLValueDetailCard(value: try list(["1", "56", "7"]).note)
        _ = card.view
        defer { card.invalidate() }
        var copied: [String] = []
        card.writeClipboard = { copied.append($0) }
        card.copyValues()
        XCTAssertEqual(copied, ["1, 56, 7"])
        card.search.stringValue = "56"
        card.updateFilter()
        XCTAssertEqual(card.table.numberOfRows, 1)
        XCTAssertEqual(card.displayedRows.first?.index, 2)
        XCTAssertEqual(card.copyButton.title, "Copiar filtrados")
        let field = card.tableView(card.table, viewFor: card.table.tableColumns[1], row: 0) as? NSTextField
        XCTAssertEqual(field?.accessibilityValue() as? String, "56")
        card.copyValues()
        XCTAssertEqual(copied.last, "56")
        card.search.stringValue = "missing"
        card.updateFilter()
        XCTAssertEqual(card.table.numberOfRows, 0)
        XCTAssertFalse(card.copyButton.isEnabled)
        card.copyValues()
        XCTAssertEqual(copied.count, 2, "No borrar el portapapeles cuando no hay valores")
        var closed = false
        card.close = { closed = true }
        XCTAssertTrue(card.control(card.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(closed)
    }

    @MainActor func testLargeListAndEmptyListUseBoundedNativeTableAndSafeCopy() throws {
        let large = SQLValueDetailCard(value: try list((1...10_000).map(String.init)).note)
        _ = large.view
        defer { large.invalidate() }
        XCTAssertEqual(large.table.numberOfRows, 10_000)
        large.search.stringValue = "10000"
        large.updateFilter()
        XCTAssertEqual(large.displayedRows.map(\.value), ["10000"])
        let empty = SQLValueDetailCard(value: try list([]).note)
        _ = empty.view
        defer { empty.invalidate() }
        XCTAssertEqual(empty.table.numberOfRows, 0)
        XCTAssertFalse(empty.copyButton.isEnabled)
    }
}
