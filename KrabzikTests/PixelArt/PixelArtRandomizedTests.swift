@testable import Krabzik
import XCTest

/// Generador determinista (SplitMix64): la misma semilla reproduce la misma secuencia, así que cualquier falla se
/// reproduce con el número que imprime el mensaje de error.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Secuencias aleatorias deterministas de operaciones (PXA-21): después de cada confirmación el estado cumple todas las
/// invariantes y sobrevive a la ida y vuelta por el almacén; un rechazo no deja cambios; y al deshacer y rehacer se
/// recorren exactamente los mismos estados, también tras guardar y reabrir.
final class PixelArtRandomizedTests: XCTestCase {
    private static let seeds: [UInt64] = [1, 2, 3, 7, 42, 99, 2_026, 31_337]
    private static let steps = 90

    private func randomOperation(_ document: PixelArtDocument, generator: inout SplitMix64) throws -> PixelOperation {
        let state = document.state
        func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &generator)] }
        func color() -> PixelRGBA {
            PixelRGBA(UInt8.random(in: 0...255, using: &generator), UInt8.random(in: 0...255, using: &generator),
                      UInt8.random(in: 0...255, using: &generator), UInt8.random(in: 1...255, using: &generator))
        }
        switch Int.random(in: 0..<19, using: &generator) {
        case 0, 1, 2:
            let writes = (0..<Int.random(in: 1...30, using: &generator)).map { _ in
                let value: PixelValue
                switch Int.random(in: 0..<4, using: &generator) {
                case 0: value = .empty
                case 1: value = state.palette.entries.isEmpty ? .free(color()) : .linked(pick(state.palette.entries).id)
                default: value = .free(color())
                }
                return PixelWrite(x: Int.random(in: 0..<state.width, using: &generator),
                                  y: Int.random(in: 0..<state.height, using: &generator), value: value)
            }
            return .writePixels(layer: pick(state.layers).id, frame: pick(state.frames).id, writes: writes)
        case 3: return .addLayer(PixelLayer(name: "Capa \(Int.random(in: 0..<1_000, using: &generator))"),
                                 at: Int.random(in: 0...state.layers.count, using: &generator))
        case 4: return .deleteLayer(pick(state.layers).id)
        case 5: return .setLayerProperty(pick(state.layers).id, .opacity(Int.random(in: 0...255, using: &generator)))
        case 6:
            let property: PixelLayerProperty = pick([
                .visible(false),
                .visible(true),
                .locked(true),
                .locked(false),
                .alphaLocked(true),
                .alphaLocked(false)
            ])
            return .setLayerProperty(pick(state.layers).id, property)
        case 7: return .moveLayer(pick(state.layers).id, to: Int.random(in: 0..<state.layers.count, using: &generator))
        case 8: return .addFrame(PixelFrame(duration: Int.random(in: 1...500, using: &generator)),
                                 at: Int.random(in: 0...state.frames.count, using: &generator))
        case 9: return .duplicateFrame(pick(state.frames).id, newID: UUID(), at: Int.random(in: 0...state.frames.count, using: &generator))
        case 10: return .deleteFrame(pick(state.frames).id)
        case 11:
            var core = document.core
            return .addPaletteEntry(PaletteEntry(id: try core.reserveEntryIDs(1)[0], color: color()))
        case 12:
            guard state.palette.entries.isEmpty == false else { return .unlinkPixels }
            return .editPaletteEntry(pick(state.palette.entries).id, name: nil, color: color(), locked: nil)
        case 13: return .reorderPalette(state.palette.entries.map(\.id).shuffled(using: &generator))
        case 14:
            guard state.palette.entries.count >= 2 else { return .unlinkPixels }
            let ids = state.palette.entries.map(\.id).shuffled(using: &generator)
            return .deletePaletteEntry(ids[0], removal: .reassign(to: ids[1]))
        case 15: return .unlinkPixels
        case 16:
            guard let entry = state.palette.entries.first else { return .unlinkPixels }
            return .linkExactMatches(color: pick([entry.color, color()]), entry: entry.id)
        case 17:
            return .resizeCanvas(width: Int.random(in: 20...90, using: &generator), height: Int.random(in: 20...90, using: &generator),
                                 offsetX: Int.random(in: -3...3, using: &generator), offsetY: Int.random(in: -3...3, using: &generator))
        default: return .addSequence(PixelSequence(name: "Secuencia", frameIDs: [pick(state.frames).id]))
        }
    }

    private func run(seed: UInt64) throws {
        var generator = SplitMix64(seed: seed)
        var document = try PixelArtDocument(width: 48, height: 48)
        var states = [document.state]
        var accepted = 0
        var rejected = 0
        for step in 0..<Self.steps {
            let operation = try randomOperation(document, generator: &generator)
            let before = document
            let transaction = PixelTransaction(label: "paso \(step)", operationKind: "random", scope: .document(document.state),
                                               operations: [operation])
            do {
                if try document.core.apply(transaction) != nil {
                    accepted += 1
                    states.append(document.state)
                    try document.state.validate()
                    XCTAssertEqual(try PixelArtFixtures.roundTrip(document.state), document.state, "semilla \(seed), paso \(step)")
                    XCTAssertEqual(document.core.history.currentState, document.core.stateRef, "semilla \(seed), paso \(step)")
                } else {
                    XCTAssertEqual(document.state, before.state,
                                   "una operación sin diferencia no cambia nada (semilla \(seed), paso \(step))")
                }
            } catch is PixelArtError {
                rejected += 1
                XCTAssertEqual(document.state, before.state, "un rechazo no deja cambios (semilla \(seed), paso \(step))")
                XCTAssertEqual(document.core.history, before.core.history, "semilla \(seed), paso \(step)")
            }
        }
        XCTAssertGreaterThan(accepted, 10,
                             "la secuencia tiene que ejercitar el motor (semilla \(seed): \(accepted) aceptadas, \(rejected) rechazadas)")

        let reopened = try PixelArtFile.read(try PixelArtFile.snapshot(of: document).data)
        XCTAssertEqual(reopened.state, document.state, "semilla \(seed)")
        XCTAssertEqual(reopened.core.history, document.core.history, "semilla \(seed)")

        var walker = reopened
        for index in stride(from: states.count - 2, through: 0, by: -1) {
            XCTAssertNotNil(try walker.core.undo(), "semilla \(seed)")
            XCTAssertEqual(walker.state, states[index], "deshacer al estado \(index), semilla \(seed)")
        }
        XCTAssertNil(try walker.core.undo())
        for index in 1..<states.count {
            XCTAssertNotNil(try walker.core.redo(), "semilla \(seed)")
            XCTAssertEqual(walker.state, states[index], "rehacer al estado \(index), semilla \(seed)")
        }
    }

    func testRandomSequencesKeepEveryInvariantAndUndoRedoWalksTheSameStates() throws {
        for seed in Self.seeds { try run(seed: seed) }
    }
}
