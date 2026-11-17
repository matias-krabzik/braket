import AppKit
import SwiftUI
@testable import Krabzik
import XCTest

@MainActor
final class SQLGridLayoutTests: XCTestCase {
    func testInitialWidthShowsCellValueAndRespectsReasonableLimit() {
        var result = SQLResult(statement: 1, line: 1)
        result.columns = ["id", "detalle"]
        result.rows = [["16930766", "una descripción completa"], ["2", "valor"]]
        let draft = SQLResultDraft(result: result)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)

        let idWidth = SQLResultGrid.preferredWidth(for: 0, in: draft, font: font, scale: 1)
        let valueWidth = ("16930766" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThanOrEqual(idWidth, valueWidth + 28)

        let detailWidth = SQLResultGrid.preferredWidth(for: 1, in: draft, font: font, scale: 1)
        XCTAssertGreaterThan(detailWidth, idWidth)
        XCTAssertLessThanOrEqual(detailWidth, 420)
    }
    func testSingleResultRowStartsBelowHeaderWithoutScrolling() async throws {
        var result = SQLResult(statement: 1, line: 1)
        result.columns = ["count(*)"]
        result.rows = [["122"]]
        let draft = SQLResultDraft(result: result)
        let host = NSHostingView(rootView: SQLResultGrid(draft: draft, scale: 1, theme: .graphite))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        func findTable(_ view: NSView) -> SQLGridTable? {
            if let table = view as? SQLGridTable { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        let table = try XCTUnwrap(findTable(host))
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let header = try XCTUnwrap(table.headerView)
        // Restore after AppKit has laid out its header, as happens when opening
        // a query in an existing results panel.
        SQLResultGrid.restoreScrollOffset(.zero, in: scroll)
        let rowRect = table.convert(table.rect(ofRow: 0), to: scroll)
        let headerRect = header.convert(header.bounds, to: scroll)
        XCTAssertEqual(SQLResultGrid.scrollOffset(in: scroll), .zero)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertGreaterThanOrEqual(rowRect.minY, headerRect.maxY - 1)
        XCTAssertLessThanOrEqual(rowRect.maxY, scroll.contentView.frame.maxY)

        var manyRows = SQLResult(statement: 2, line: 1)
        manyRows.columns = ["id"]
        manyRows.rows = (1...100).map { [String($0)] }
        let other = SQLResultDraft(result: manyRows)
        host.rootView = SQLResultGrid(draft: other, scale: 1, theme: .graphite)
        try await Task.sleep(nanoseconds: 100_000_000)
        SQLResultGrid.restoreScrollOffset(NSPoint(x: 0, y: 200), in: scroll)
        host.rootView = SQLResultGrid(draft: draft, scale: 1, theme: .graphite)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(SQLResultGrid.scrollOffset(in: scroll).y, 0, accuracy: 1)
        XCTAssertGreaterThanOrEqual(table.convert(table.rect(ofRow: 0), to: scroll).minY,
                                    header.convert(header.bounds, to: scroll).maxY - 1)
        host.rootView = SQLResultGrid(draft: other, scale: 1, theme: .graphite)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(SQLResultGrid.scrollOffset(in: scroll).y, 200, accuracy: 1)

    }

}
