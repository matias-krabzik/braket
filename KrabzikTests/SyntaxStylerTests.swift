import AppKit
@testable import Krabzik
import XCTest

/// `SyntaxStyler` no tenía pruebas: seis expresiones regulares aplicadas sobre el texto
/// visible, una de ellas (`/* … */`) con riesgo de comportarse mal ante entradas
/// patológicas. Ver docs/specs/C9-cobertura-pruebas.md.
@MainActor
final class SyntaxStylerTests: XCTestCase {
    private func storage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        storage.addAttribute(.foregroundColor, value: EditorPalette.text,
                             range: NSRange(location: 0, length: (text as NSString).length))
        return storage
    }

    /// Color aplicado al primer carácter de `fragment` dentro del texto.
    private func color(of fragment: String, in text: String, language: String = "SQL") throws -> NSColor {
        let store = storage(text)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        SyntaxStyler.apply(to: store, range: whole, language: language)
        let location = (text as NSString).range(of: fragment).location
        XCTAssertNotEqual(location, NSNotFound, "«\(fragment)» tiene que estar en el texto")
        let value = store.attribute(.foregroundColor, at: location, effectiveRange: nil)
        return try XCTUnwrap(value as? NSColor)
    }

    /// `tokens` descarta en silencio una expresión que no compile, así que hace falta
    /// comprobar que cada una pinta algo. Se usa una palabra clave en minúsculas porque
    /// las de mayúsculas las vuelve a pintar otra regla (ver la prueba de abajo).
    func testPatternsCompile() throws {
        let code = "let total = suma(1) // nota\n$x = 'a'\nFactura\n"
        XCTAssertEqual(try color(of: "let", in: code, language: "PHP"), EditorPalette.purple)
        XCTAssertEqual(try color(of: "1", in: code, language: "PHP"), EditorPalette.orange)
        XCTAssertEqual(try color(of: "Factura", in: code, language: "PHP"), EditorPalette.blue)
        XCTAssertEqual(try color(of: "$x", in: code, language: "PHP"), EditorPalette.purple)
        XCTAssertEqual(try color(of: "suma", in: code, language: "PHP"), EditorPalette.blue)
        XCTAssertEqual(try color(of: "// nota", in: code, language: "PHP"), EditorPalette.muted)
    }

    /// Comportamiento actual, no necesariamente el deseado: las reglas se aplican en
    /// orden y cada una repinta, así que `\b[A-Z][A-Za-z0-9_]*\b` —pensada para nombres
    /// de tipo— gana sobre la de palabras clave en todo lo que esté en mayúsculas. En SQL,
    /// que se escribe así por convención, eso significa que `SELECT` sale con el color de
    /// un tipo. Cambiarlo es cambiar el tema del editor, y no es lo que cubre C9: queda
    /// anotado en el spec.
    func testUppercaseKeywordsEndUpWithTheTypeColor() throws {
        let sql = "SELECT 1 FROM t WHERE id = 2\n"
        XCTAssertEqual(try color(of: "SELECT", in: sql), EditorPalette.blue)
        // Y en minúsculas no queda coloreada en absoluto: las palabras de SQL están en la
        // lista solo en mayúsculas, y la expresión distingue mayúsculas de minúsculas.
        XCTAssertEqual(try color(of: "select", in: "select 1\n"), EditorPalette.text)
    }

    func testSQLKeywordsLiteralsAndComments() throws {
        let sql = "SELECT nombre FROM clientes WHERE id = 42 AND activo = 'si'\n-- un comentario\n"
        XCTAssertEqual(try color(of: "SELECT", in: sql), EditorPalette.blue)
        XCTAssertEqual(try color(of: "42", in: sql), EditorPalette.orange)
        XCTAssertEqual(try color(of: "'si'", in: sql), EditorPalette.green)
        XCTAssertEqual(try color(of: "-- un comentario", in: sql), EditorPalette.muted)
        XCTAssertEqual(try color(of: "nombre", in: sql), EditorPalette.text, "un identificador no se pinta")
    }

    func testPHPVariablesCallsAndBlockComments() throws {
        let php = "<?php\n$total = suma(1, 2)\n/* bloque */ class Factura {}\n"
        XCTAssertEqual(try color(of: "$total", in: php, language: "PHP"), EditorPalette.purple)
        XCTAssertEqual(try color(of: "suma", in: php, language: "PHP"), EditorPalette.blue)
        XCTAssertEqual(try color(of: "/* bloque */", in: php, language: "PHP"), EditorPalette.muted)
        XCTAssertEqual(try color(of: "Factura", in: php, language: "PHP"), EditorPalette.blue)
    }

    func testCommentsWinOverKeywordsInsideThem() throws {
        let code = "// SELECT 1\n"
        XCTAssertEqual(try color(of: "SELECT", in: code, language: "TypeScript"), EditorPalette.muted,
                       "una palabra clave dentro de un comentario queda apagada")
    }

    func testPlainTextAndMarkdownAreNotTouched() {
        for language in ["Texto", "Markdown"] {
            let text = "SELECT 'algo' // no es código\n"
            let store = storage(text)
            store.addAttribute(.foregroundColor, value: NSColor.red,
                               range: NSRange(location: 0, length: (text as NSString).length))
            SyntaxStyler.apply(to: store, range: NSRange(location: 0, length: (text as NSString).length),
                               language: language)
            XCTAssertEqual(store.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                           NSColor.red, "\(language) no se colorea")
        }
    }

    func testEmptyRangeDoesNothing() {
        let store = storage("SELECT 1")
        store.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 8))
        SyntaxStyler.apply(to: store, range: NSRange(location: 0, length: 0), language: "SQL")
        XCTAssertEqual(store.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.red)
    }

    /// El comentario de bloque usa `[\s\S]*?`, que con muchos `/*` sin cerrar puede
    /// degradarse. El editor acota el rango a 60.000 caracteres; esto comprueba que ni
    /// siquiera el peor caso dentro de ese tope se va de tiempo.
    func testPathologicalInputFinishesQuickly() throws {
        let text = String(repeating: "/*", count: 20_000)   // 40.000 caracteres sin cerrar
        let store = storage(text)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let start = DispatchTime.now()
        SyntaxStyler.apply(to: store, range: whole, language: "PHP")
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        XCTAssertLessThan(ms, 2_000, "\(Int(ms)) ms para 40.000 caracteres de «/*» sin cerrar")
    }

    func testColoringIsRelativeToTheRequestedRange() throws {
        let text = "linea uno\nSELECT 1\n"
        let store = storage(text)
        let second = (text as NSString).range(of: "SELECT 1\n")
        SyntaxStyler.apply(to: store, range: second, language: "SQL")
        XCTAssertEqual(store.attribute(.foregroundColor, at: second.location, effectiveRange: nil) as? NSColor,
                       EditorPalette.blue, "el desplazamiento del rango se tiene en cuenta")
        XCTAssertEqual(store.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       EditorPalette.text, "fuera del rango no se toca nada")
    }
}
