@testable import Krabzik
import XCTest

final class MarkdownBlocksTests: XCTestCase {
    func testFencedCodeAndTableStaySeparateFromSurroundingText() {
        let blocks = MarkdownBlocks.parse("""
        # Notas

        Texto con **énfasis**.

        ```swift
        let count = 1
        ```

        Nombre | Versión
        --- | ---
        Braket | 0.5.4

        ![Icono](../Design/icon.png)
        """)
        XCTAssertEqual(blocks, [
            .heading(1, "Notas"),
            .paragraph("Texto con **énfasis**."),
            .code("swift", "let count = 1"),
            .table([["Nombre", "Versión"], ["Braket", "0.5.4"]]),
            .image("Icono", "../Design/icon.png")
        ])
    }

    func testHorizontalRuleDoesNotBecomeTable() {
        XCTAssertEqual(MarkdownBlocks.parse("Antes\n\n---\n\nDespués"), [
            .paragraph("Antes"), .rule, .paragraph("Después")
        ])
    }
}
