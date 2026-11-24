import AppKit
@testable import Krabzik
import SwiftUI
import XCTest

@MainActor final class SQLForeignKeyTests: XCTestCase {
    private let source = SQLTableIdentity(database: "qa", table: "Users")
    private var key: SQLForeignKey {
        SQLForeignKey(name: "fk_org", columns: ["organization_id"], columnTypes: ["bigint unsigned"],
                      database: "companies", table: "Organization", referencedColumns: ["id"])
    }
    private func draft() -> SQLResultDraft {
        var result = SQLResult(statement: 1, line: 1)
        result.columns = ["user_id", "org_alias"]
        result.origins = [.init(database: "qa", table: "Users", column: "id"),
                          .init(database: "qa", table: "Users", column: "organization_id")]
        result.rows = [["1", "18446744073709551614"], ["2", nil]]
        result.rowCount = 2
        let draft = SQLResultDraft(result: result)
        draft.relations.keys[source] = [key]
        return draft
    }
    func testUsesRealOriginsAndExactKeysNotColumnNameHeuristics() throws {
        let draft = draft()
        let target = try XCTUnwrap(draft.relations.targets(row: 0, column: 1, draft: draft).first)
        XCTAssertEqual(target.query, "SELECT * FROM `companies`.`Organization` WHERE `id` = 18446744073709551614;")
        XCTAssertTrue(target.previewQuery.hasSuffix("LIMIT 100;"))
        XCTAssertTrue(draft.relations.targets(row: 0, column: 0, draft: draft).isEmpty)
        XCTAssertTrue(draft.relations.targets(row: 1, draft: draft).isEmpty)
        draft.deleted.insert(0)
        XCTAssertTrue(draft.relations.targets(row: 0, draft: draft).isEmpty)
    }
    func testCompositeKeysRequireAllColumnsAndEscapeValues() throws {
        let foreign = SQLForeignKey(name: "composite", columns: ["id", "organization_id"], columnTypes: ["varchar(50)", "bigint"],
                                    database: "db`name", table: "Organization", referencedColumns: ["tenant", "id"])
        let draft = draft()
        draft.relations.keys[source] = [foreign]
        draft.changes[SQLCell(row: 0, column: 0)] = .text("O'Brien")
        let target = try XCTUnwrap(draft.relations.targets(row: 0, draft: draft).first)
        XCTAssertEqual(target.query, "SELECT * FROM `db``name`.`Organization` WHERE `tenant` = 'O''Brien' "
                       + "AND `id` = 18446744073709551614;")
        draft.changes[SQLCell(row: 0, column: 1)] = .serverDefault
        XCTAssertTrue(draft.relations.targets(row: 0, draft: draft).isEmpty)
        draft.relations.keys[source] = [SQLForeignKey(name: "missing", columns: ["not_selected"], columnTypes: ["int"],
                                                      database: "qa", table: "Org", referencedColumns: ["id"])]
        XCTAssertTrue(draft.relations.targets(row: 0, draft: draft).isEmpty)
    }
    func testMetadataGroupingKeepsCompositeOrderAndSeparatesConstraints() {
        let rows: [[String?]] = [
            ["Users", "fk_org", "tenant", "qa", "Org", "tenant", "varchar(30)"],
            ["Users", "fk_org", "organization_id", "qa", "Org", "id", "bigint"],
            ["Users", "fk_manager", "manager_id", "qa", "Users", "id", "bigint"]
        ]
        let keys = SQLForeignKey.grouped(rows)["Users"] ?? []
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.first { $0.name == "fk_org" }?.columns, ["tenant", "organization_id"])
        XCTAssertEqual(keys.first { $0.name == "fk_org" }?.referencedColumns, ["tenant", "id"])
        XCTAssertTrue(SQLForeignKey.query(database: "a'b", table: "Users").contains("k.TABLE_SCHEMA = 'a''b'"))
    }
    func testCardLoadsAndCollapsesWithoutChangingParentRows() async throws {
        let draft = draft()
        let target = try XCTUnwrap(draft.relations.targets(row: 0, draft: draft).first)
        draft.relations.load = { _ in
            var result = SQLResult(statement: 0, line: 1)
            result.columns = ["id", "name"]
            result.rows = [["18446744073709551614", "Demo"]]
            return result
        }
        draft.relations.toggle(target, row: 0)
        let record = try XCTUnwrap(draft.relations.expanded[0])
        for _ in 0..<100 where record.loading { await Task.yield() }
        XCTAssertFalse(record.loading)
        XCTAssertEqual(record.result?.rows.first?[1], "Demo")
        XCTAssertEqual(draft.rowCount, 2)
        XCTAssertFalse(draft.hasChanges)
        draft.relations.toggle(target, row: 0)
        XCTAssertNil(draft.relations.expanded[0])
    }
    func testNativeCardRailAndCommandClickKeepResultRowsAndKeyboardEditing() async throws {
        let draft = draft()
        var result = draft.result
        result.sql = "SELECT * FROM qa.Users"
        let editable = SQLResultDraft(result: result)
        editable.relations.keys = draft.relations.keys
        editable.configure(SQLSchemaTable(database: "qa", name: "Users", kind: "BASE TABLE", engine: "InnoDB", columns: [
            SQLSchemaColumn(name: "id", type: "bigint", nullable: false, extra: ""),
            SQLSchemaColumn(name: "organization_id", type: "bigint unsigned", nullable: true, extra: "")
        ], uniqueKeys: [["id"]], primaryKey: ["id"]))
        editable.widths[0] = 450
        editable.widths[1] = 120
        editable.relations.load = { _ in
            var value = SQLResult(statement: 0, line: 1)
            value.columns = ["id", "name", "country"]
            value.rows = [["18446744073709551614", "Organización Demo", "AR"]]
            return value
        }
        var opened: SQLRelatedTarget?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 430),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Braket Desarrollo · Relaciones"
        window.contentView = NSHostingView(rootView: SQLResultGrid(draft: editable, scale: 1, theme: .graphite,
                                                                   openRelated: { opened = $0 }))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let found = view as? T { return found }
            return view.subviews.lazy.compactMap { find(type, in: $0) }.first
        }
        let content = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(find(SQLGridTable.self, in: content))
        let coordinator = try XCTUnwrap(table.delegate as? SQLResultGrid.Coordinator)
        coordinator.activateRelation(row: 0, column: -1, point: .zero, newTab: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertGreaterThan(table.rect(ofRow: 0).height, 130)
        XCTAssertGreaterThan(table.rect(ofRow: 1).minY, 130)
        let rail = try XCTUnwrap(find(SQLRelationRail.self, in: content))
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertGreaterThanOrEqual(rail.frame.minX, scroll.contentView.frame.maxX)
        XCTAssertEqual(rail.subviews.count, 1, "Solo la fila con una FK no nula ofrece el botón")
        let fittedHeight = table.rect(ofRow: 0).height
        window.setContentSize(NSSize(width: 360, height: 430))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(table.rect(ofRow: 0).height, fittedHeight + 10,
                             "Solo una tabla que desborda reserva espacio para el scroll horizontal")
        window.setContentSize(NSSize(width: 780, height: 430))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(table.rect(ofRow: 0).height, fittedHeight, accuracy: 1,
                       "Al volver a caber, el footer queda pegado a la última fila")

        editable.widths[1] = 44
        try await Task.sleep(for: .milliseconds(100))
        let narrow = try XCTUnwrap(table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? SQLGridCellView)
        narrow.layoutSubtreeIfNeeded()
        XCTAssertFalse(narrow.relationButton.isHidden)
        XCTAssertGreaterThanOrEqual(narrow.relationButton.frame.minX, 0)
        XCTAssertLessThanOrEqual(narrow.relationButton.frame.maxX, narrow.bounds.maxX)
        XCTAssertLessThan(narrow.valueLabel.frame.maxX, narrow.relationButton.frame.minX)
        XCTAssertFalse(narrow.valueLabel.stringValue.contains("\u{FFFC}"), "El botón no forma parte del texto de la celda")
        narrow.relationButton.performClick(nil)
        XCTAssertNil(editable.relations.expanded[0])
        narrow.relationButton.performClick(nil)
        XCTAssertNotNil(editable.relations.expanded[0])
        editable.widths[1] = 120
        try await Task.sleep(for: .milliseconds(150))
        let record = try XCTUnwrap(editable.relations.expanded[0])
        XCTAssertNotNil(record.elapsed)
        let layout = SQLRelationLayout(scale: 1, interfaceScale: Theme.settings.uiScale)
        XCTAssertGreaterThanOrEqual(record.cardHeight(scale: 1), layout.headerHeight + layout.footerHeight
                                    + layout.tableHeight(rows: 1) + 2 * layout.outerInset)

        let point = table.convert(NSPoint(x: table.rect(ofColumn: 0).midX, y: table.rect(ofRow: 0).minY + 10), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .command,
                                                     timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        table.mouseDown(with: event)
        XCTAssertEqual(opened?.key.table, "Organization")
        XCTAssertFalse(editable.hasChanges)
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            try image.write(to: root.appendingPathComponent(".build/foreign-key-preview.png"))
        }
        coordinator.beginEditing(row: 0, column: 1)
        XCTAssertNil(editable.relations.expanded[0])
        XCTAssertTrue(editable.isEditingCell)
        coordinator.cellEditor?.cancelEditing()
    }

    func testCollapsedRequestCannotRestoreItsCardAndFailuresAreVisible() async throws {
        let draft = draft()
        let target = try XCTUnwrap(draft.relations.targets(row: 0, draft: draft).first)
        draft.relations.load = { _ in
            try await Task.sleep(for: .milliseconds(50))
            throw DatabaseFailure("Sin permiso")
        }
        draft.relations.toggle(target, row: 0)
        draft.relations.collapse(0)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(draft.relations.expanded[0])
        draft.relations.load = { _ in throw DatabaseFailure("Sin permiso") }
        draft.relations.toggle(target, row: 0)
        let record = try XCTUnwrap(draft.relations.expanded[0])
        for _ in 0..<100 where record.loading { await Task.yield() }
        XCTAssertTrue(record.error?.contains("Sin permiso") == true)
    }
}
