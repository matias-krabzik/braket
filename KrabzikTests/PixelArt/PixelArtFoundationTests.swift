@testable import Krabzik
import XCTest

/// JSON estricto, color, bloques y estado de PXA-01 §1, §3–§4 y PXA-03 §1–§3.
final class PixelArtFoundationTests: XCTestCase {
    // MARK: JSON

    func testCanonicalJSONSortsKeysByUTF8AndOmitsSpaces() {
        let value = PixelArtJSON.object(["b": .int(1), "a": .array([.bool(true), .null]), "é": .string("x\n\"y\"")])
        XCTAssertEqual(String(decoding: value.canonicalData(), as: UTF8.self), #"{"a":[true,null],"b":1,"é":"x\n\"y\""}"#)
    }

    func testStrictParserRejectsWhatTheContractForbids() {
        let rejected = ["\u{FEFF}{}", #"{"a":1,"a":2}"#, "{} x", #"{"a":1,}"#, "[1,]", #"{"a":01}"#, #"{"a":1e999}"#,
                        #""\ud800""#, #""\x""#, "{\"a\":\"\t\"}", "// c\n{}", "nul"]
        for text in rejected {
            XCTAssertThrowsError(try PixelArtJSON.parse(Data(text.utf8), section: "t"), text)
        }
        XCTAssertThrowsError(try PixelArtJSON.parse(Data([0x7B, 0xFF, 0x7D]), section: "t"), "UTF-8 inválido")
    }

    func testParserLimitsDepthAtSixtyFour() throws {
        func nested(_ levels: Int) -> Data { Data((String(repeating: "[", count: levels) + String(repeating: "]", count: levels)).utf8) }
        XCTAssertNoThrow(try PixelArtJSON.parse(nested(64), section: "t"))
        XCTAssertThrowsError(try PixelArtJSON.parse(nested(65), section: "t")) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .limit)
        }
    }

    func testParserRoundTripsUnicodeAndEscapes() throws {
        let value = PixelArtJSON.object(["clave": .string("línea\u{1}\u{1F600}\\/")])
        XCTAssertEqual(try PixelArtJSON.parse(value.canonicalData(), section: "t"), value)
        XCTAssertEqual(try PixelArtJSON.parse(Data(#""😀""#.utf8), section: "t"), .string("\u{1F600}"))
    }

    func testFieldsRejectUnknownKeysAndWrongTypes() throws {
        let object = PixelArtJSON.object(["a": .int(1), "extra": .bool(true)])
        let fields = try PixelArtFields(object, section: "t")
        XCTAssertEqual(try fields.int("a"), 1)
        XCTAssertThrowsError(try fields.finish())
        XCTAssertThrowsError(try fields.string("a"))
        XCTAssertThrowsError(try PixelArtFields(.int(1), section: "t"))
    }

    // MARK: Bloques

    func testTileStoresThreeClassesAndNormalizesFreeAlphaZero() {
        var tile = PixelTile.empty
        tile[1, 2] = .free(PixelArtFixtures.red)
        tile[3, 4] = .linked(4_294_967_294)
        tile[5, 6] = .free(PixelRGBA(9, 9, 9, 0))
        XCTAssertEqual(tile[1, 2], .free(PixelArtFixtures.red))
        XCTAssertEqual(tile[3, 4], .linked(4_294_967_294))
        XCTAssertEqual(tile[5, 6], .empty)
        XCTAssertEqual(tile.bytes.count, 5_120)
        XCTAssertEqual(tile.linkedIDs, [4_294_967_294])
    }

    func testTileValidationRejectsBrokenData() throws {
        func make(_ edit: (inout [UInt8]) -> Void) -> Data {
            var bytes = [UInt8](repeating: 0, count: PxaTile.byteCount)
            edit(&bytes)
            return Data(bytes)
        }
        func validate(_ data: Data, at coord: TileCoord = TileCoord(x: 0, y: 0), ids: Set<UInt32> = [7]) throws {
            _ = try PixelTile.validate(data, at: coord, width: 40, height: 40, paletteIDs: ids, section: "t")
        }
        XCTAssertThrowsError(try validate(Data(count: 10)), "tamaño")
        XCTAssertThrowsError(try validate(make { $0[0] = 3 }), "etiqueta desconocida")
        XCTAssertThrowsError(try validate(make { $0[0] = 1 }), "libre con alfa cero")
        XCTAssertThrowsError(try validate(make { $0[1] = 5 }), "vacío con carga")
        XCTAssertThrowsError(try validate(make { $0[0] = 2 }), "ID cero")
        XCTAssertThrowsError(try validate(make { $0[0] = 2
        $0[1] = 8 }), "ID inexistente")
        XCTAssertNoThrow(try validate(make { $0[0] = 2
        $0[1] = 7 }))
        let outside = make { $0[(0 * 32 + 20) * 5] = 1
        $0[(0 * 32 + 20) * 5 + 4] = 255 }
        XCTAssertThrowsError(try validate(outside, at: TileCoord(x: 1, y: 0)), "píxel fuera del lienzo en un borde")
        XCTAssertNoThrow(try validate(outside, at: TileCoord(x: 0, y: 0)))
    }

    func testLinkedAlphaZeroIsKeptAndHiddenUntilTheEntryChanges() throws {
        var state = PixelArtState.blank(width: 4, height: 4)
        state.palette.entries = [PaletteEntry(id: 1, color: PixelRGBA(0, 255, 0, 0))]
        state.frames[0].cels[state.layers[0].id] = {
            var cel = PixelCel()
            cel.setPixel(x: 1, y: 1, to: .linked(1))
            return cel
        }()
        XCTAssertNoThrow(try state.validate())
        let frame = state.frames[0].id
        XCTAssertEqual(PixelArtRenderer.render(state, frame: frame).pixel(x: 1, y: 1).alpha, 0)
        state.palette.entries[0].color.alpha = 255
        XCTAssertEqual(PixelArtRenderer.render(state, frame: frame).pixel(x: 1, y: 1), PixelRGBA(0, 255, 0, 255))
    }

    func testSelectionBitOrderIsMostSignificantFirstAndEmptyDiffersFromNone() throws {
        var tile = SelectionTile.empty
        tile[0, 0] = true
        tile[7, 0] = true
        tile[0, 1] = true
        XCTAssertEqual(tile.bytes[0], 0b1000_0001)
        XCTAssertEqual(tile.bytes[4], 0b1000_0000)
        let selection = PixelSelection.rectangle(x: 30, y: 2, width: 4, height: 2, canvasWidth: 40, canvasHeight: 40)
        XCTAssertTrue(selection.contains(x: 33, y: 3))
        XCTAssertFalse(selection.contains(x: 34, y: 3))
        XCTAssertEqual(selection.tiles.count, 2)
        let explicitEmpty: PixelSelection? = PixelSelection()
        XCTAssertNotNil(explicitEmpty)
        XCTAssertTrue(explicitEmpty?.isEmpty == true)
        XCTAssertThrowsError(try SelectionTile.validate(Data(count: 3), at: TileCoord(x: 0, y: 0), width: 8, height: 8, section: "t"))
        var outside = SelectionTile.empty
        outside[9, 0] = true
        XCTAssertThrowsError(try SelectionTile.validate(Data(outside.bytes), at: TileCoord(x: 0, y: 0), width: 8, height: 8, section: "t"))
    }

    // MARK: Estado

    func testStateValidationEnforcesTheModelLimits() throws {
        XCTAssertNoThrow(try PixelArtFixtures.mixedState().validate())
        var state = PixelArtFixtures.mixedState()
        state.width = 4_097
        XCTAssertThrowsError(try state.validate())
        state = .blank(width: 4_096, height: 4_096)
        XCTAssertNoThrow(try state.validate())
        state.height = 4_097
        XCTAssertThrowsError(try state.validate())

        state = PixelArtFixtures.mixedState()
        state.layers[1].id = state.layers[0].id
        XCTAssertThrowsError(try state.validate(), "ID de capa repetido")
        state = PixelArtFixtures.mixedState()
        state.frames[0].duration = 0
        XCTAssertThrowsError(try state.validate())
        state.frames[0].duration = 60_001
        XCTAssertThrowsError(try state.validate())
        state = PixelArtFixtures.mixedState()
        state.sequences[0].frameIDs = [UUID()]
        XCTAssertThrowsError(try state.validate(), "secuencia con fotograma inexistente")
        state.sequences[0].frameIDs = []
        XCTAssertThrowsError(try state.validate(), "secuencia vacía")
        state = PixelArtFixtures.mixedState()
        state.frames[0].cels[UUID()] = PixelCel()
        XCTAssertThrowsError(try state.validate(), "celda de una capa inexistente")
    }

    func testPaletteCapacityAtMostTwoHundredFiftySix() throws {
        var state = PixelArtState.blank(width: 2, height: 2)
        state.palette.entries = (1...256).map { PaletteEntry(id: UInt32($0), color: PixelArtFixtures.red) }
        XCTAssertNoThrow(try state.validate())
        state.palette.entries.append(PaletteEntry(id: 257, color: PixelArtFixtures.red))
        XCTAssertThrowsError(try state.validate())
    }

    func testNamesRejectControlsAndBidiButAllowEmptyEntryNames() {
        XCTAssertNoThrow(try PixelArtText.validateName("Capa ñandú 🙂", section: "t"))
        for bad in ["a\nb", "a\u{0}b", "a\u{202E}b", "a\u{85}b", ""] {
            XCTAssertThrowsError(try PixelArtText.validateName(bad, section: "t"), bad)
        }
        XCTAssertThrowsError(try PixelArtText.validateName(String(repeating: "a", count: 201), section: "t"))
        XCTAssertThrowsError(try PixelArtText.validateName(String(repeating: "ñ", count: 401), section: "t"), "800 bytes")
        XCTAssertNoThrow(try PixelArtText.validateMessage("hola\n\tmundo", section: "t"))
        XCTAssertThrowsError(try PixelArtText.validateMessage("a\u{1}", section: "t"))
    }

    // MARK: Codificación de objetos

    func testMixedStateRoundTripsExactly() throws {
        let state = PixelArtFixtures.mixedState()
        XCTAssertEqual(try PixelArtFixtures.roundTrip(state), state)
    }

    func testEncodingIsDeterministicAndDeduplicates() {
        var first = PxaObjectStore()
        var second = PxaObjectStore()
        let state = PixelArtFixtures.mixedState()
        XCTAssertEqual(PixelArtStateCodec.encode(state, into: &first), PixelArtStateCodec.encode(state, into: &second))
        let before = first.count
        _ = PixelArtStateCodec.encode(state, into: &first)
        XCTAssertEqual(first.count, before, "guardar lo mismo dos veces no agrega objetos")
    }

    /// Editar un píxel de un fotograma no duplica los bloques del resto de la animación (PXA-02 §2).
    func testEditingOnePixelAddsOnlyTheObjectsOnItsPath() {
        var store = PxaObjectStore()
        var state = PixelArtFixtures.mixedState()
        _ = PixelArtStateCodec.encode(state, into: &store)
        let before = store.count
        state.frames[0].cels[state.layers[0].id]?.setPixel(x: 2, y: 0, to: .free(PixelArtFixtures.blue))
        _ = PixelArtStateCodec.encode(state, into: &store)
        // Bloque nuevo, su celda, su fotograma y el estado raíz.
        XCTAssertEqual(store.count - before, 4)
    }

    func testDuplicatedCelSharesObjectsButEditsIndependently() throws {
        var state = PixelArtFixtures.mixedState()
        let layer = state.layers[0].id
        state.frames[1].cels[layer] = state.frames[0].cels[layer]
        state.frames[1].cels[layer]?.setPixel(x: 0, y: 0, to: .free(PixelArtFixtures.blue))
        XCTAssertEqual(state.frames[0].cels[layer]?.pixel(x: 0, y: 0), .linked(7))
        XCTAssertEqual(try PixelArtFixtures.roundTrip(state), state)
    }

    func testDecodeRejectsTamperedMissingAndMistypedObjects() throws {
        var store = PxaObjectStore()
        let ref = PixelArtStateCodec.encode(PixelArtFixtures.mixedState(), into: &store)
        let tile = try XCTUnwrap(store.objects.first { $0.value.count == PxaTile.byteCount })
        var tampered = store.objects
        tampered[tile.key] = Data(count: PxaTile.byteCount)
        XCTAssertThrowsError(try PixelArtStateCodec.decode(ref, from: PxaObjectStore(objects: tampered))) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .integrity)
        }
        var missing = store.objects
        missing[tile.key] = nil
        XCTAssertThrowsError(try PixelArtStateCodec.decode(ref, from: PxaObjectStore(objects: missing)))
        let wrong = PxaObjectRef(type: .layer, hash: ref.hash, size: ref.size)
        XCTAssertThrowsError(try PixelArtStateCodec.decode(wrong, from: store))
    }

    func testReachabilityFindsEveryObjectOfAStateAndNothingElse() throws {
        var store = PxaObjectStore()
        let ref = PixelArtStateCodec.encode(PixelArtFixtures.mixedState(), into: &store)
        let live = try store.reachable(from: [ref])
        XCTAssertEqual(live, store.hashes)
        store.put(Data("huérfano".utf8), type: .assistantImage)
        XCTAssertEqual(try store.reachable(from: [ref]).count, live.count)
        XCTAssertEqual(store.pruned(keeping: live).count, live.count)
    }

    // MARK: Composición y color (PXA-01 §3, PXA-03 §9)

    func testCompositionUsesLinearLightAndLayerOpacity() throws {
        var state = PixelArtState.blank(width: 2, height: 1)
        state.layers.append(PixelLayer(name: "Frente", opacity: 255))
        let frame = state.frames[0].id
        state.frames[0].cels[state.layers[0].id] = {
            var cel = PixelCel()
            cel.setPixel(x: 0, y: 0, to: .free(PixelRGBA(255, 255, 255)))
            return cel
        }()
        state.frames[0].cels[state.layers[1].id] = {
            var cel = PixelCel()
            cel.setPixel(x: 0, y: 0, to: .free(PixelRGBA(0, 0, 0, 128)))
            cel.setPixel(x: 1, y: 0, to: .free(PixelRGBA(255, 0, 0, 255)))
            return cel
        }()
        let bitmap = PixelArtRenderer.render(state, frame: frame)
        // Negro con alfa 128/255 sobre blanco deja 0,498 de luz lineal, que en sRGB es 187,19 → 187.
        XCTAssertEqual(bitmap.pixel(x: 0, y: 0), PixelRGBA(187, 187, 187, 255))
        XCTAssertEqual(bitmap.pixel(x: 1, y: 0), PixelRGBA(255, 0, 0, 255))

        state.layers[1].opacity = 0
        XCTAssertEqual(PixelArtRenderer.render(state, frame: frame).pixel(x: 0, y: 0), PixelRGBA(255, 255, 255, 255))
        state.layers[1].opacity = 255
        state.layers[1].visible = false
        XCTAssertEqual(PixelArtRenderer.render(state, frame: frame).pixel(x: 1, y: 0).alpha, 0)
        XCTAssertEqual(PixelArtRenderer.render(state, frame: frame, layerIDs: [state.layers[1].id]).pixel(x: 1, y: 0).alpha, 255)
    }

    func testEditingAPaletteEntryChangesOnlyLinkedPixels() throws {
        var state = PixelArtFixtures.mixedState()
        let frame = state.frames[0].id
        state.palette.entries[0].color = PixelArtFixtures.blue
        let bitmap = PixelArtRenderer.render(state, frame: frame)
        XCTAssertEqual(bitmap.pixel(x: 0, y: 0), PixelArtFixtures.blue, "vinculado a 7")
        XCTAssertEqual(bitmap.pixel(x: 1, y: 0), PixelArtFixtures.red, "libre con el mismo rojo")
        XCTAssertEqual(bitmap.pixel(x: 39, y: 39), PixelArtFixtures.red, "vinculado a 9, mismo rojo inicial")
        state.palette.entries.reverse()
        XCTAssertEqual(PixelArtRenderer.render(state, frame: frame), bitmap, "reordenar la paleta no cambia nada")
    }

    func testColorDistanceMatchesTheSpecAndTiesAreStable() {
        XCTAssertEqual(PixelRGBA(10, 20, 30, 255).distance(to: PixelRGBA(10, 20, 30, 255)), 0)
        XCTAssertEqual(PixelRGBA(0, 0, 0, 0).distance(to: PixelRGBA(255, 255, 255, 0)), 0, "dos transparentes coinciden")
        XCTAssertEqual(PixelRGBA(0, 0, 0, 255).distance(to: PixelRGBA(255, 255, 255, 255)), 3, accuracy: 1e-12)
        XCTAssertEqual(PixelRGBA(0, 0, 0, 255).distance(to: PixelRGBA(0, 0, 0, 0)), 1, accuracy: 1e-12)
        XCTAssertEqual(PixelRGBA.linear(255), 1, accuracy: 1e-12)
        XCTAssertEqual(PixelRGBA.encode(linear: 0.5), 188)
        XCTAssertEqual(PixelRGBA.encode(linear: 2), 255)
        XCTAssertEqual(PixelRGBA.encode(linear: -1), 0)
    }
}
