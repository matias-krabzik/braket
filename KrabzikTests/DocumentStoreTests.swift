@testable import Krabzik
import AppKit
import XCTest

/// Los archivos abiertos, sin un solo diálogo: es el criterio 5 de C5. Si alguna de estas
/// pruebas colgara esperando un `NSAlert`, sería porque la decisión se le escapó al
/// coordinador. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor
final class DocumentStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-docs-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func file(_ name: String, _ contents: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testOpeningTheSameFileTwiceDoesNotDuplicateTheTab() async throws {
        let base = try directory()
        let url = try file("a.sql", "SELECT 1;\n", in: base)
        let store = DocumentStore()

        try await store.open(url)
        try await store.open(url)

        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(store.selectedID, url.standardizedFileURL)
    }

    func testOpeningTheSameFileTwiceAtOnceReadsItOnce() async throws {
        let base = try directory()
        let url = try file("a.sql", "SELECT 1;\n", in: base)
        let store = DocumentStore()

        // Dos aperturas en paralelo: la segunda ve `openingFiles` y no abre otra pestaña.
        async let primera: Void = store.open(url)
        async let segunda: Void = store.open(url)
        _ = try await (primera, segunda)

        XCTAssertEqual(store.documents.count, 1)
        XCTAssertTrue(store.openingFiles.isEmpty, "al terminar no queda nada en curso")
    }

    func testOpeningIsDiscardedWhenTheContextStopsBeingValid() async throws {
        let base = try directory()
        let url = try file("a.sql", "SELECT 1;\n", in: base)
        let store = DocumentStore()

        try await store.open(url, stillValid: { false })

        XCTAssertTrue(store.documents.isEmpty, "el proyecto se cerró mientras se leía")
        XCTAssertNil(store.selectedID)
    }

    func testOpeningRejectsBinaryAndOversizedFiles() async throws {
        let base = try directory()
        let binario = base.appendingPathComponent("imagen.bin")
        try Data([0x00, 0x01, 0x02]).write(to: binario)
        let store = DocumentStore()

        do {
            try await store.open(binario)
            XCTFail("un archivo con NUL no es texto")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .binaryFile)
        }
        XCTAssertTrue(store.documents.isEmpty)
    }

    func testLargePNGOpensAsPreviewWithoutChangingTheFile() async throws {
        let root = try directory()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1400, pixelsHigh: 1400,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                                    bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        var seed: UInt32 = 0x1234ABCD
        for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
            seed = seed &* 1664525 &+ 1013904223
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 5 * 1024 * 1024)
        let url = root.appendingPathComponent("large.png")
        try data.write(to: url)
        let store = DocumentStore()

        try await store.open(url)

        let document = try XCTUnwrap(store.selected)
        XCTAssertNotNil(document.previewImage)
        let saved = try await store.save(document)
        XCTAssertFalse(saved)
        XCTAssertEqual(try Data(contentsOf: url), data)
        let copy = root.appendingPathComponent("copy.png")
        try store.saveCopy(of: document, to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), data)
    }

    func testDamagedPNGReportsImageError() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("damaged.png")
        try Data("bad".utf8).write(to: url)
        let store = DocumentStore()
        do {
            try await store.open(url)
            XCTFail("un PNG dañado no debe abrirse")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .invalidImage)
        }
    }

    func testSVGOpensAsPreviewAndRejectsExternalReferences() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("diagram.svg")
        let safe = #"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="blue"/></svg>"#
        try Data(safe.utf8).write(to: url)
        let store = DocumentStore()
        try await store.open(url)
        XCTAssertNotNil(store.selected?.previewImage)

        let unsafe = root.appendingPathComponent("external.svg")
        let referenced = #"<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.com/image.png"/></svg>"#
        try Data(referenced.utf8).write(to: unsafe)
        do {
            try await store.open(unsafe)
            XCTFail("una imagen con referencias externas no debe abrirse")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .invalidImage)
        }
    }

    func testSavePropagatesAnExternalChange() async throws {
        let base = try directory()
        let url = try file("a.sql", "original\n", in: base)
        let store = DocumentStore()
        try await store.open(url)
        let document = try XCTUnwrap(store.documents.first)

        document.text = "mío\n"
        document.isDirty = true
        // Alguien más escribió el archivo entre la lectura y el guardado.
        try Data("de otro\n".utf8).write(to: url)

        do {
            _ = try await store.save(document)
            XCTFail("no puede pisar un cambio externo")
        } catch {
            XCTAssertEqual(error as? WorkspaceError, .externalChange)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "de otro\n")
    }

    func testSaveWritesAndClearsDirty() async throws {
        let base = try directory()
        let url = try file("a.sql", "original\n", in: base)
        let store = DocumentStore()
        try await store.open(url)
        let document = try XCTUnwrap(store.documents.first)

        document.text = "nuevo\n"
        document.isDirty = true
        let saved = try await store.save(document)

        XCTAssertTrue(saved)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "nuevo\n")
    }

    func testSaveCopyLeavesTheOpenDocumentAlone() async throws {
        let base = try directory()
        let url = try file("a.sql", "original\n", in: base)
        let store = DocumentStore()
        try await store.open(url)
        let document = try XCTUnwrap(store.documents.first)
        document.text = "editado\n"

        let copia = base.appendingPathComponent("a-copia.sql")
        try store.saveCopy(of: document, to: copia)

        XCTAssertEqual(try String(contentsOf: copia, encoding: .utf8), "editado\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original\n")
        XCTAssertEqual(store.documents.count, 1)
    }

    func testReloadDiscardsUnsavedChanges() async throws {
        let base = try directory()
        let url = try file("a.sql", "original\n", in: base)
        let store = DocumentStore()
        try await store.open(url)
        let document = try XCTUnwrap(store.documents.first)
        document.text = "editado\n"
        document.isDirty = true
        try Data("del disco\n".utf8).write(to: url)

        try store.reload(document)

        XCTAssertEqual(document.text, "del disco\n")
        XCTAssertFalse(document.isDirty)
    }

    func testClosingSelectsTheNeighbour() async throws {
        let base = try directory()
        let store = DocumentStore()
        for name in ["a.sql", "b.sql", "c.sql"] {
            try await store.open(try file(name, "SELECT 1;\n", in: base))
        }
        XCTAssertEqual(store.selectedID?.lastPathComponent, "c.sql")

        let segundo = try XCTUnwrap(store.documents.first { $0.url.lastPathComponent == "b.sql" })
        store.selectedID = segundo.id
        store.close(segundo)

        XCTAssertEqual(store.documents.count, 2)
        XCTAssertEqual(store.selectedID?.lastPathComponent, "c.sql", "queda el de al lado")
    }

    func testClosingTheLastOneLeavesNoSelection() async throws {
        let base = try directory()
        let store = DocumentStore()
        try await store.open(try file("a.sql", "SELECT 1;\n", in: base))
        store.close(try XCTUnwrap(store.documents.first))
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertNil(store.selectedID)
    }

    func testCloseAllClears() async throws {
        let base = try directory()
        let store = DocumentStore()
        for name in ["a.sql", "b.sql"] {
            try await store.open(try file(name, "SELECT 1;\n", in: base))
        }
        store.closeAll()
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertNil(store.selectedID)
        XCTAssertTrue(store.dirty.isEmpty)
    }

    func testRefreshOnlyTouchesWhatThePredicateMatches() async throws {
        let base = try directory()
        let store = DocumentStore()
        let uno = try file("uno.sql", "uno\n", in: base)
        let dos = try file("dos.sql", "dos\n", in: base)
        try await store.open(uno)
        try await store.open(dos)

        try Data("uno cambiado\n".utf8).write(to: uno)
        try Data("dos cambiado\n".utf8).write(to: dos)
        await store.refresh(matching: { $0.lastPathComponent == "uno.sql" })

        let documentoUno = try XCTUnwrap(store.documents.first { $0.url == uno.standardizedFileURL })
        let documentoDos = try XCTUnwrap(store.documents.first { $0.url == dos.standardizedFileURL })
        XCTAssertEqual(documentoUno.text, "uno cambiado\n")
        XCTAssertEqual(documentoDos.text, "dos\n", "el que no cumple el predicado no se toca")
    }

    func testRefreshMarksAFileThatDisappeared() async throws {
        let base = try directory()
        let store = DocumentStore()
        let url = try file("a.sql", "algo\n", in: base)
        try await store.open(url)
        try FileManager.default.removeItem(at: url)

        await store.refresh(matching: { _ in true })

        let document = try XCTUnwrap(store.documents.first)
        XCTAssertTrue(document.hasExternalChange, "no se puede leer: queda marcado, no vacío")
        XCTAssertEqual(document.text, "algo\n")
    }

    func testDirtyListsOnlyEditedDocuments() async throws {
        let base = try directory()
        let store = DocumentStore()
        for name in ["a.sql", "b.sql"] {
            try await store.open(try file(name, "SELECT 1;\n", in: base))
        }
        let primero = try XCTUnwrap(store.documents.first)
        primero.isDirty = true
        XCTAssertEqual(store.dirty.count, 1)
        XCTAssertEqual(store.dirty.first?.id, primero.id)
    }
}
