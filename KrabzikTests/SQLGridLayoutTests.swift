import AppKit
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
}
