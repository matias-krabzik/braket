@testable import Krabzik
import XCTest

/// Contenedor ZIP y manifiesto de PXA-01 §1–§2 y §8.
final class PxaContainerTests: XCTestCase {
    private func entry(_ name: String, _ text: String) -> PxaZip.Entry { PxaZip.Entry(name: name, data: Data(text.utf8)) }

    private func objectEntry(_ payload: Data) -> PxaZip.Entry {
        PxaZip.Entry(name: PxaZip.objectName(PxaObjectStore.hash(of: payload)), data: payload)
    }

    private func sampleManifest() -> PxaManifest {
        var store = PxaObjectStore()
        let state = PixelArtStateCodec.encode(PixelArtFixtures.mixedState(), into: &store)
        let other = store.put(.historyIndex, fields: [:])
        let editor = store.put(.editorState, fields: [:])
        let presets = store.put(.exportPresets, fields: [:])
        return PxaManifest(documentID: UUID(), saveID: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                           savedAt: Date(timeIntervalSince1970: 1_700_000_100), writerVersion: "0.5.15", currentState: state,
                           history: other, editorState: editor, exportPresets: presets, nextPaletteEntryID: 10,
                           objectCount: 4, uncompressedBytes: 1_234)
    }

    // MARK: ZIP

    func testRoundTripKeepsEntriesAndIsDeterministic() throws {
        let big = Data((0..<20_000).map { UInt8($0 % 7) })
        let entries = [entry("manifest.json", "{}"), objectEntry(big), objectEntry(Data("corto".utf8)), objectEntry(Data())]
        let archive = try PxaZip.write(entries)
        XCTAssertEqual(try PxaZip.read(archive), entries)
        XCTAssertEqual(try PxaZip.write(entries), archive, "mismo contenido, mismos bytes")
        XCTAssertLessThan(archive.count, big.count, "lo compresible se comprime")
    }

    func testIncompressibleDataIsStoredAndReadBack() throws {
        var generator = SystemRandomNumberGenerator()
        let noise = Data((0..<4_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let entries = [objectEntry(noise)]
        XCTAssertEqual(try PxaZip.read(try PxaZip.write(entries)), entries)
    }

    func testRejectsEntryNamesOutsideTheContract() throws {
        let bad = ["../manifest.json", "/etc/passwd", "objects/../x", "objects\\ab", "objects/", "otra.txt", "objects/ABC", "preview.PNG",
                   "objects/" + String(repeating: "a", count: 63), "objects/" + String(repeating: "A", count: 64)]
        for name in bad {
            XCTAssertThrowsError(try PxaZip.write([entry(name, "x")]), name)
        }
        XCTAssertThrowsError(try PxaZip.write([entry("manifest.json", "a"), entry("manifest.json", "b")]), "duplicada")
    }

    /// Un ZIP armado a mano con un nombre peligroso, que el escritor nunca produciría.
    func testRejectsHostileNamesInAForgedArchive() throws {
        let archive = try PxaZip.write([entry("manifest.json", "{}")])
        var forged = archive
        let needle = Data("manifest.json".utf8)
        let replacement = Data("../anifest.json".prefix(needle.count).utf8)
        var searchStart = forged.startIndex
        while let range = forged.range(of: needle, in: searchStart..<forged.endIndex) {
            forged.replaceSubrange(range, with: replacement)
            searchStart = range.upperBound
        }
        XCTAssertThrowsError(try PxaZip.read(forged))
    }

    func testRejectsDamagedCRCAndTruncatedFiles() throws {
        let archive = try PxaZip.write([entry("manifest.json", String(repeating: "dato", count: 100))])
        var flipped = archive
        flipped[50] ^= 0xFF  // dentro de los datos: 30 de encabezado + 13 del nombre
        XCTAssertThrowsError(try PxaZip.read(flipped))
        XCTAssertThrowsError(try PxaZip.read(archive.prefix(archive.count - 5)))
        XCTAssertThrowsError(try PxaZip.read(Data()))
        XCTAssertThrowsError(try PxaZip.read(Data("esto no es un zip, solo texto largo para pasar el mínimo".utf8)))
    }

    /// El CRC se comprueba aunque los datos y los tamaños sean coherentes: un dato alterado que descomprime
    /// bien no puede pasar por íntegro.
    func testRejectsAWrongCRCEvenWhenSizesAndDataAreCoherent() throws {
        let archive = try PxaZip.write([entry("manifest.json", "{}")])
        var forged = archive
        let central = try XCTUnwrap(forged.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        forged[central.lowerBound + 16] ^= 0xFF
        XCTAssertThrowsError(try PxaZip.read(forged)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .integrity)
            XCTAssertTrue(error.localizedDescription.contains("CRC"))
        }
    }

    func testRejectsLyingSizesBeforeAllocating() throws {
        let archive = try PxaZip.write([objectEntry(Data(repeating: 1, count: 5_000))])
        var forged = archive
        // El tamaño descomprimido del directorio central se infla por encima del tope de un objeto.
        let central = try XCTUnwrap(forged.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        let sizeOffset = central.lowerBound + 24
        forged.replaceSubrange(sizeOffset..<sizeOffset + 4, with: [0x00, 0x00, 0x00, 0x7F])
        XCTAssertThrowsError(try PxaZip.read(forged)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .limit)
        }
    }

    func testRejectsDeflateThatInflatesBeyondItsDeclaredSize() throws {
        let archive = try PxaZip.write([objectEntry(Data(repeating: 9, count: 10_000))])
        var forged = archive
        let central = try XCTUnwrap(forged.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        let sizeOffset = central.lowerBound + 24
        forged.replaceSubrange(sizeOffset..<sizeOffset + 4, with: [0x10, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try PxaZip.read(forged))
    }

    func testRejectsEncryptedEntriesAndSymlinks() throws {
        let archive = try PxaZip.write([entry("manifest.json", "{}")])
        var encrypted = archive
        let central = try XCTUnwrap(encrypted.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
        encrypted[central.lowerBound + 8] |= 0x01
        XCTAssertThrowsError(try PxaZip.read(encrypted))

        var link = archive
        let mode: UInt32 = 0o120_777 << 16
        link.replaceSubrange(central.lowerBound + 38..<central.lowerBound + 42,
                             with: (0..<4).map { UInt8((mode >> (8 * UInt32($0))) & 0xFF) })
        XCTAssertThrowsError(try PxaZip.read(link))
    }

    func testZip64CarriesMoreThanSixtyFiveThousandEntries() throws {
        let entries = (0..<70_000).map { index in objectEntry(Data("objeto \(index)".utf8)) }
        let archive = try PxaZip.write(entries)
        let back = try PxaZip.read(archive)
        XCTAssertEqual(back.count, 70_000)
        XCTAssertEqual(Set(back.map(\.name)), Set(entries.map(\.name)))
    }

    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(PxaZip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(PxaZip.crc32(Data()), 0)
    }

    // MARK: Manifiesto

    func testManifestRoundTripsExactly() throws {
        var manifest = sampleManifest()
        manifest.copiedFrom = UUID()
        manifest.partialHistory = true
        manifest.extensions = ["nota": .string("opcional")]
        XCTAssertEqual(try PxaManifest.parse(manifest.data()), manifest)
        XCTAssertEqual(manifest.data(), manifest.data())
        XCTAssertEqual(manifest.roots.count, 4)
    }

    func testManifestRejectsForeignFormatsAndUnknownFields() throws {
        let valid = try XCTUnwrap(try PixelArtJSON.parse(sampleManifest().data(), section: "t"))
        func manifestData(_ edit: (inout [String: PixelArtJSON]) -> Void) throws -> Data {
            guard case .object(var fields) = valid else { return Data() }
            edit(&fields)
            return PixelArtJSON.object(fields).canonicalData()
        }
        XCTAssertThrowsError(try PxaManifest.parse(manifestData { $0["format"] = .string("otro") }))
        XCTAssertThrowsError(try PxaManifest.parse(manifestData { $0["campoNuevo"] = .int(1) }))
        XCTAssertThrowsError(try PxaManifest.parse(manifestData { $0["nextPaletteEntryID"] = .int(0) }))
        XCTAssertThrowsError(try PxaManifest.parse(manifestData { $0["createdAt"] = .string("ayer") }))
        XCTAssertThrowsError(try PxaManifest.parse(manifestData { $0["saveID"] = .string("no-uuid") }))
        XCTAssertThrowsError(try PxaManifest.parse(manifestData { $0["requiredFeatures"] = .array([.string("tilemaps")]) }))
        XCTAssertThrowsError(try PxaManifest.parse(manifestData { $0.removeValue(forKey: "history") }))
        XCTAssertThrowsError(try PxaManifest.parse(Data(count: PxaLimits.manifestBytes + 1)))
    }

    func testFutureMajorIsRejectedAndFutureMinorIsReadOnly() throws {
        let valid = try XCTUnwrap(try PixelArtJSON.parse(sampleManifest().data(), section: "t"))
        guard case .object(var fields) = valid else { return XCTFail("manifiesto sin objeto") }
        fields["formatVersion"] = .object(["major": .int(2), "minor": .int(0)])
        XCTAssertThrowsError(try PxaManifest.parse(PixelArtJSON.object(fields).canonicalData())) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .unsupported)
            XCTAssertTrue(error.localizedDescription.contains("actualiza"))
        }
        fields["formatVersion"] = .object(["major": .int(1), "minor": .int(3)])
        fields["campoDelFuturo"] = .bool(true)
        let future = try PxaManifest.parse(PixelArtJSON.object(fields).canonicalData())
        XCTAssertTrue(future.isReadOnly)
        XCTAssertFalse(sampleManifest().isReadOnly)
    }
}
