import AppKit
@testable import Krabzik
import XCTest

final class SQLTableReferenceTests: XCTestCase {
    private func reference(_ sql: String, _ clicked: String) -> SQLTableReference? {
        SQLTableReference.at((sql as NSString).range(of: clicked, options: .backwards).location, in: sql)
    }

    func testSourcesAndQualifiedIdentifiers() {
        for prefix in ["SELECT * FROM", "SELECT * FROM x JOIN", "UPDATE", "INSERT INTO", "DELETE FROM", "SHOW CREATE TABLE"] {
            let sql = prefix + " `db`.`Orders`"
            let expected = SQLTableReference(database: "db", name: "Orders")
            XCTAssertEqual(reference(sql, "Orders"), expected)
            XCTAssertEqual(reference(sql, "db"), expected)
        }
        XCTAssertEqual(reference("SELECT * FROM a, Orders", "Orders"), SQLTableReference(database: nil, name: "Orders"))
        XCTAssertEqual(reference("SELECT * FROM x WHERE id IN (SELECT id FROM Orders)", "Orders")?.name, "Orders")
        XCTAssertEqual(reference("SELECT '😀' FROM `déb`.`Órd``ers`", "Órd")?.name, "Órd`ers")
    }

    func testOnlyTableReferencesAreNavigable() {
        for sql in ["SELECT Orders FROM x", "SELECT * FROM x AS Orders", "SELECT * FROM x WHERE Orders = 1",
                    "SELECT * FROM x -- FROM Orders", "SELECT 'FROM Orders'", "SELECT * FROM x WHERE a IN (1, Orders)",
                    "SELECT * FROM x ORDER BY a, Orders", "SELECT * FROM (SELECT 1) Orders",
                    "WITH Orders AS (SELECT 1) SELECT * FROM Orders"] {
            XCTAssertNil(reference(sql, "Orders"), sql)
        }
        XCTAssertNil(SQLTableReference.at(-1, in: "FROM x"))
        XCTAssertNil(SQLTableReference.at(6, in: "FROM x"))
        XCTAssertEqual(reference("WITH Orders AS (SELECT 1) SELECT 1; SELECT * FROM Orders", "Orders")?.name, "Orders")
    }

    @MainActor func testCommandClickNavigatesWithoutChangingTextOrSelection() throws {
        let code = "SELECT * FROM `db`.`Orders`;"
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/navigation.sql"), data: Data(code.utf8))
        let surface = EditorSurface(document: document)
        defer { surface.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.layoutIfNeeded()
        let view = surface.textView
        let position = (code as NSString).range(of: "Orders").location
        var navigated: Int?
        view.openTableDefinition = { navigated = $0 }
        view.setSelectedRange(NSRange(location: 0, length: 6))
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphRange(forCharacterRange: NSRange(location: position, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyph, in: container)
        let point = view.convert(NSPoint(x: rect.midX + view.textContainerOrigin.x,
                                         y: rect.midY + view.textContainerOrigin.y), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .command,
                                                     timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        XCTAssertEqual(navigated, position)
        XCTAssertEqual(view.string, code)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 6))
    }

    @MainActor func testDefinitionOpensCleanIndependentTab() throws {
        let store = DocumentStore()
        let original = try store.createDraft(name: "consulta.sql", text: "SELECT 1")
        let table = SQLSchemaTable(database: "db", name: "Orders", kind: "BASE TABLE", engine: "InnoDB")
        let definition = try store.openTableDefinition(table, sql: "CREATE TABLE `Orders` (`id` INT);")
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(store.selectedID, definition.id)
        XCTAssertTrue(definition.isTableDefinition)
        XCTAssertFalse(definition.isDirty)
        XCTAssertEqual(definition.language, "SQL")
        XCTAssertEqual(original.text, "SELECT 1")
        XCTAssertTrue(original.isDirty)
    }
}
