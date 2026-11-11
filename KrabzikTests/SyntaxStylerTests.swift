import AppKit
@testable import Krabzik
import XCTest

@MainActor final class SyntaxStylerTests: XCTestCase {
    private func spans(_ text: String, extension suffix: String) async -> [SyntaxSpan] {
        let syntax = SyntaxHighlighter(text: text, url: URL(fileURLWithPath: "/tmp/example.\(suffix)"))
        return await syntax.highlights(in: NSRange(location: 0, length: text.utf16.count))
    }

    private func color(_ fragment: String, in text: String, spans: [SyntaxSpan]) -> NSColor? {
        let offset = (text as NSString).range(of: fragment).location
        return spans.last { NSLocationInRange(offset, $0.range) }?.color
    }

    func testLanguageSpecificKeywordsAndLiterals() async {
        let examples = [
            ("swift", "let total = 42 // nota", "let"),
            ("ts", "const total = 42 // nota", "const"),
            ("js", "const total = 42 // nota", "const"),
            ("py", "return 42 # nota", "return"),
            ("dart", "int answer() { return 42; } // nota", "return"),
            ("go", "package main\nfunc main() { return }", "package"),
            ("rs", "fn main() { let total = 42; }", "fn")
        ]
        for (suffix, code, keyword) in examples {
            let result = await spans(code, extension: suffix)
            XCTAssertFalse(result.isEmpty, suffix)
            XCTAssertEqual(color(keyword, in: code, spans: result), EditorPalette.purple, suffix)
        }
    }

    func testSQLKeywordsAreCaseInsensitive() async {
        for keyword in ["SELECT", "select"] {
            let code = "\(keyword) 42 FROM clientes -- nota\n"
            let result = await spans(code, extension: "sql")
            XCTAssertEqual(color(keyword, in: code, spans: result), EditorPalette.purple)
            XCTAssertEqual(color("42", in: code, spans: result), EditorPalette.orange)
            XCTAssertEqual(color("nota", in: code, spans: result), EditorPalette.muted)
        }
    }

    func testVisibleRangeRetainsMultilineContext() async {
        let code = "/* comienza\nconst falso = 42\ntermina */\nconst real = 1;"
        let syntax = SyntaxHighlighter(text: code, url: URL(fileURLWithPath: "/tmp/test.js"))
        let range = (code as NSString).range(of: "const falso = 42")
        let result = await syntax.highlights(in: range)
        XCTAssertEqual(color("const falso", in: code, spans: result), EditorPalette.muted)
        XCTAssertTrue(result.allSatisfy { NSIntersectionRange($0.range, range) == $0.range })
    }

    func testIncrementalUnicodeEditsAndUndo() async {
        let original = "// 🦀 café\nconst total = 42;\n"
        let syntax = SyntaxHighlighter(text: original, url: URL(fileURLWithPath: "/tmp/test.js"))
        _ = await syntax.highlights(in: NSRange(location: 0, length: original.utf16.count))
        let range = (original as NSString).range(of: "42")
        syntax.replace(range, with: "'🐙'")
        let edited = (original as NSString).replacingCharacters(in: range, with: "'🐙'")
        let result = await syntax.highlights(in: NSRange(location: 0, length: edited.utf16.count))
        XCTAssertEqual(color("🐙", in: edited, spans: result), EditorPalette.green)
        syntax.replace(NSRange(location: range.location, length: "'🐙'".utf16.count), with: "42")
        let restored = await syntax.highlights(in: NSRange(location: 0, length: original.utf16.count))
        XCTAssertEqual(color("42", in: original, spans: restored), EditorPalette.orange)
    }

    func testRemovingCommentOpenerUpdatesLaterLines() async {
        let original = "/*\nconst total = 42;\n*/"
        let syntax = SyntaxHighlighter(text: original, url: URL(fileURLWithPath: "/tmp/test.js"))
        _ = await syntax.highlights(in: NSRange(location: 0, length: original.utf16.count))
        syntax.replace(NSRange(location: 0, length: 2), with: "")
        let edited = String(original.dropFirst(2))
        let result = await syntax.highlights(in: NSRange(location: 0, length: edited.utf16.count))
        XCTAssertEqual(color("const", in: edited, spans: result), EditorPalette.purple)
    }

    func testStructuredLanguagesAndPlainText() async {
        for (suffix, code) in [("json", "{\"title\": true}"), ("html", "<div>Hello</div>"),
                               ("css", "body { color: red; }"), ("php", "<?php echo 'hola';"),
                               ("tsx", "const view = <div>Hello</div>;"), ("md", "# Title\n"),
                               ("yaml", "title: hello"), ("sh", "echo 'hello'")] {
            let result = await spans(code, extension: suffix)
            XCTAssertFalse(result.isEmpty, suffix)
        }
        let plain = await spans("const total = 42", extension: "txt")
        XCTAssertTrue(plain.isEmpty)
    }

    func testHTMLScriptsAndStylesUseTheirOwnGrammars() async {
        let code = "<h1>🦀 café</h1><script>const total = 42; // nota\n</script>" +
            "<style>body { width: 12px; color: #abc; }</style><p>const plain = 7;</p>"
        let result = await spans(code, extension: "html")
        XCTAssertEqual(color("h1", in: code, spans: result), EditorPalette.blue)
        XCTAssertEqual(color("const total", in: code, spans: result), EditorPalette.purple)
        XCTAssertEqual(color("42", in: code, spans: result), EditorPalette.orange)
        XCTAssertEqual(color("nota", in: code, spans: result), EditorPalette.muted)
        XCTAssertEqual(color("body", in: code, spans: result), EditorPalette.blue)
        XCTAssertEqual(color("12", in: code, spans: result), EditorPalette.orange)
        XCTAssertEqual(color("abc", in: code, spans: result), EditorPalette.green)
        XCTAssertNil(color("const plain", in: code, spans: result))
    }

    func testHTMLVisibleRangeRetainsEmbeddedCommentContextAndBlockIsolation() async {
        let code = "<script>/* comentario\nconst hidden = 42; */</script>" +
            "<script>/* sin cerrar</script><script>const visible = 1;</script>"
        let syntax = SyntaxHighlighter(text: code, url: URL(fileURLWithPath: "/tmp/test.html"))
        let range = (code as NSString).range(of: "const hidden = 42;")
        let result = await syntax.highlights(in: range)
        XCTAssertEqual(color("const hidden", in: code, spans: result), EditorPalette.muted)
        XCTAssertTrue(result.allSatisfy { NSIntersectionRange($0.range, range) == $0.range })
        let all = await syntax.highlights(in: NSRange(location: 0, length: code.utf16.count))
        XCTAssertEqual(color("const visible", in: code, spans: all), EditorPalette.purple)
    }

    func testHTMLUnfinishedAndEmptyEmbeddedBlocks() async {
        for code in ["<script></script><script>const value = 42;", "<style></style><style>p { width: 42px;"] {
            let result = await spans(code, extension: "html")
            XCTAssertEqual(color("42", in: code, spans: result), EditorPalette.orange)
        }
    }

    func testHTMLScriptTypesAndComments() async {
        let code = "<script TYPE='module'>export const total = 1;</script>" +
            "<script type='application/ld+json'>{\"count\": 42}</script>" +
            "<script type='text/template'>const plain = 7;</script>" +
            "<!-- <script>const comment = 2;</script> -->"
        let result = await spans(code, extension: "html")
        XCTAssertEqual(color("export", in: code, spans: result), EditorPalette.purple)
        XCTAssertEqual(color("42", in: code, spans: result), EditorPalette.orange)
        XCTAssertNil(color("const plain", in: code, spans: result))
        XCTAssertEqual(color("const comment", in: code, spans: result), EditorPalette.muted)
    }

    func testHTMLEmbeddedEditsMatchFreshParseIncludingUnicodeAndUndo() async {
        var code = "<p>🦀</p><script>const count = 42;</script><style>p { width: 12px; }</style>"
        let syntax = SyntaxHighlighter(text: code, url: URL(fileURLWithPath: "/tmp/test.html"))
        _ = await syntax.highlights(in: NSRange(location: 0, length: code.utf16.count))
        let edits = [("🦀", "🐙\n🎉"), ("42", "'café 🦀'"), ("12", "25"),
                     ("const count", "/*\nconst count"), ("/*\n", ""), ("'café 🦀'", "42"),
                     ("<script>", "<script type='text/template'>"),
                     ("<script type='text/template'>", "<script>"),
                     ("<style>p { width: 25px; }</style>", "")]
        for (old, replacement) in edits {
            let range = (code as NSString).range(of: old)
            XCTAssertNotEqual(range.location, NSNotFound)
            syntax.replace(range, with: replacement)
            code = (code as NSString).replacingCharacters(in: range, with: replacement)
            let incremental = await syntax.highlights(in: NSRange(location: 0, length: code.utf16.count))
            let fresh = await spans(code, extension: "html")
            XCTAssertEqual(incremental.map { "\($0.range):\($0.token)" }, fresh.map { "\($0.range):\($0.token)" }, old)
        }
    }

    func testApplyingColorsPreservesTextSelectionAndUndo() async throws {
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/test.js"), data: Data("const x = 1;".utf8))
        let surface = EditorSurface(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = surface
        let view = surface.textView
        window.makeFirstResponder(view)
        let undo = try XCTUnwrap(view.undoManager)
        undo.beginUndoGrouping()
        view.setSelectedRange(NSRange(location: 10, length: 1))
        view.insertText("42", replacementRange: view.selectedRange())
        undo.endUndoGrouping()
        let selection = view.selectedRange()
        let code = view.string
        let result = await spans(code, extension: "js")
        SyntaxHighlighter.apply(result, to: try XCTUnwrap(view.textStorage), range: NSRange(location: 0, length: code.utf16.count))
        XCTAssertEqual(view.string, "const x = 42;")
        XCTAssertEqual(view.selectedRange(), selection)
        undo.undo()
        XCTAssertEqual(view.string, "const x = 1;")
        surface.teardown()
    }
}
