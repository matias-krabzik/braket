@testable import Krabzik
import XCTest

/// Máximos y máximos + 1 de PXA-01 §6, comprobados antes de reservar memoria grande.
final class PxaLimitsTests: XCTestCase {
    private func state(layers: Int = 1, frames: Int = 1, sequences: Int = 0) -> PixelArtState {
        var value = PixelArtState.blank(width: 4, height: 4)
        value.layers = (0..<layers).map { PixelLayer(name: "C\($0)") }
        value.frames = (0..<frames).map { _ in PixelFrame() }
        value.sequences = (0..<sequences).map { PixelSequence(name: "S\($0)", frameIDs: [value.frames[0].id]) }
        return value
    }

    func testCanvasAxisAndPixelBudget() {
        XCTAssertNoThrow(try PixelArtState.blank(width: 4_096, height: 4_096).validate())
        XCTAssertThrowsError(try PixelArtState.blank(width: 4_097, height: 1).validate())
        XCTAssertThrowsError(try PixelArtState.blank(width: 1, height: 4_097).validate())
        XCTAssertThrowsError(try PixelArtState.blank(width: 0, height: 1).validate())
        XCTAssertNoThrow(try PixelArtState.blank(width: 1, height: 1).validate())
    }

    func testLayersFramesAndSequencesAtTheirCaps() {
        XCTAssertNoThrow(try state(layers: 128).validate())
        XCTAssertThrowsError(try state(layers: 129).validate())
        XCTAssertNoThrow(try state(frames: 1_024).validate())
        XCTAssertThrowsError(try state(frames: 1_025).validate())
        XCTAssertNoThrow(try state(sequences: 256).validate())
        XCTAssertThrowsError(try state(sequences: 257).validate())
        var empty = state()
        empty.layers = []
        XCTAssertThrowsError(try empty.validate(), "al menos una capa")
        empty = state()
        empty.frames = []
        XCTAssertThrowsError(try empty.validate(), "al menos un fotograma")
    }

    /// 65.536 posiciones de bloque cuentan aunque compartan hash: son posiciones, no objetos distintos.
    func testTilePositionsAreCountedEvenWhenTheyShareContent() {
        var tile = PixelTile.empty
        tile[0, 0] = .free(PixelRGBA(1, 2, 3))
        var value = PixelArtState.blank(width: 4_096, height: 4_096)
        value.layers = (0..<5).map { PixelLayer(name: "C\($0)") }
        var cel = PixelCel()
        for y in 0..<128 {
            for x in 0..<128 { cel.tiles[TileCoord(x: x, y: y)] = tile }
        }
        for layer in value.layers.prefix(4) { value.frames[0].cels[layer.id] = cel }
        XCTAssertEqual(value.tilePositionCount, 65_536)
        XCTAssertNoThrow(try value.validate(deepTiles: false))
        var one = PixelCel()
        one.tiles[TileCoord(x: 0, y: 0)] = tile
        value.frames[0].cels[value.layers[4].id] = one
        XCTAssertEqual(value.tilePositionCount, 65_537)
        XCTAssertThrowsError(try value.validate(deepTiles: false)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .limit)
        }
    }

    func testRevisionCountAtTheCapAndOneMore() throws {
        let ref = PxaObjectRef(type: .documentState, hash: String(repeating: "a", count: 64), size: 10)
        func chain(_ count: Int) throws -> PixelHistory {
            var revisions: [PixelRevision] = []
            revisions.reserveCapacity(count)
            for index in 0..<count {
                revisions.append(PixelRevision(parentID: index == 0 ? nil : revisions[index - 1].id, beforeState: index == 0 ? nil : ref,
                                               afterState: ref, operationKind: "t", label: "r"))
            }
            return try PixelHistory(revisions: revisions, rootID: revisions[0].id, cursorID: revisions[count - 1].id,
                                    preferredChild: [:], bookmarks: [])
        }
        XCTAssertNoThrow(try chain(PxaLimits.revisions))
        XCTAssertThrowsError(try chain(PxaLimits.revisions + 1)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .limit)
        }
    }

    func testObjectCountAndEntrySizeLimitsAreEnforcedBeforeBuildingAnything() throws {
        let entries = (0..<(PxaLimits.objects + 3)).map { index in
            PxaZip.Entry(name: PxaZip.objectName(PxaObjectStore.hash(of: Data("\(index)".utf8))), data: Data())
        }
        XCTAssertThrowsError(try PxaZip.write(entries)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .limit)
        }
        var store = PxaObjectStore()
        let huge = store.put(Data(count: 10), type: .pixelTile)
        XCTAssertEqual(huge.size, 10)
        XCTAssertThrowsError(try PxaObjectRef(json: PxaObjectRef(type: .layer, hash: String(repeating: "b", count: 64),
                                                                 size: PxaLimits.jsonObjectBytes + PxaLimits.imageBytes + 1).json,
                                              section: "t", expecting: .layer), "tamaño declarado fuera de rango")
    }

    func testPaletteEntryIDBoundsAndTheExhaustedCounter() throws {
        var state = PixelArtState.blank(width: 2, height: 2)
        state.palette.entries = [PaletteEntry(id: PxaLimits.paletteEntryIDMax, color: PixelRGBA(1, 2, 3))]
        XCTAssertNoThrow(try state.validate())
        state.palette.entries[0].id = 0
        XCTAssertThrowsError(try state.validate(), "0 está reservado")
        state.palette.entries[0].id = 4_294_967_295
        XCTAssertThrowsError(try state.validate(), "4.294.967.295 es el contador agotado, no un ID")
        XCTAssertEqual(PxaLimits.paletteCounterExhausted, 4_294_967_295)
    }

    func testObjectsAreRejectedWhenTheirJSONIsTooLargeOrTooDeep() throws {
        var store = PxaObjectStore()
        let bigName = String(repeating: "a", count: PxaLimits.jsonObjectBytes)
        let ref = store.put(.layer, fields: ["name": .string(bigName)])
        XCTAssertThrowsError(try store.fields(ref)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .limit)
        }
        var deep = PixelArtJSON.int(1)
        for _ in 0..<70 { deep = .array([deep]) }
        let deepRef = store.put(.layer, fields: ["x": deep])
        XCTAssertThrowsError(try store.fields(deepRef))
    }
}
