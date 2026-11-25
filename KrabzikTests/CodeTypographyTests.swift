import AppKit
@testable import Krabzik
import XCTest

@MainActor
final class CodeTypographyTests: XCTestCase {
    func testEveryChoiceHasRealRegularAndBoldMonospacedFaces() {
        XCTAssertGreaterThanOrEqual(CodeFontFamily.allCases.count, 5)
        for family in CodeFontFamily.allCases {
            let regular = family.nativeFont(size: 16)
            let bold = family.nativeFont(size: 16, bold: true)
            XCTAssertNotEqual(regular.fontName, bold.fontName, family.title)
            if family != .systemMono {
                XCTAssertTrue(regular.familyName?.replacingOccurrences(of: " ", with: "").lowercased()
                    == family.title.replacingOccurrences(of: " ", with: "").lowercased(), family.title)
            }
            for font in [regular, bold] {
                let narrow = ("iiii" as NSString).size(withAttributes: [.font: font]).width
                let wide = ("WWWW" as NSString).size(withAttributes: [.font: font]).width
                XCTAssertEqual(narrow, wide, accuracy: 0.1, family.title)
            }
        }
    }
    func testCodeAndResultsPersistIndependentlyAndOldSettingsKeepTheirDefaults() throws {
        let suite = "braket-typography-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.codeTypography, CodeTypography())
        XCTAssertEqual(settings.resultTypography, CodeTypography())
        settings.codeTypography = CodeTypography(family: .jetBrainsMono, bold: true)
        settings.resultTypography = CodeTypography(family: .sourceCodePro)
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.codeTypography, settings.codeTypography)
        XCTAssertEqual(restored.resultTypography, settings.resultTypography)
        XCTAssertEqual(restored.codeFontSize, 14)
        XCTAssertEqual(restored.resultFontSize, 14)
    }
    func testChangingOnlyTypefacePreservesEditorHistoryAndSelection() async throws {
        let previous = Theme.settings
        let suite = "braket-font-preview-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        Theme.settings = settings
        defer { Theme.settings = previous }
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/font-test.sql"), data: Data("SELECT 1;".utf8))
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        defer { surface.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        surface.applyZoom(1)
        let history = try XCTUnwrap(surface.textView.undoManager)
        surface.textView.insertText("2", replacementRange: NSRange(location: 7, length: 1))
        try await Task.sleep(for: .milliseconds(40))
        surface.textView.setSelectedRange(NSRange(location: 7, length: 1))
        let before = surface.textView.string
        settings.codeTypography = CodeTypography(family: .firaCode, bold: true)
        surface.applyZoom(1)
        XCTAssertEqual(surface.textView.string, before)
        XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 7, length: 1))
        XCTAssertEqual(surface.textView.font?.familyName, "Fira Code")
        history.undo()
        XCTAssertEqual(surface.textView.string, "SELECT 1;")
        history.redo()
        XCTAssertEqual(surface.textView.string, before)
    }
}
