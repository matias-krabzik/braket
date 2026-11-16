@testable import Krabzik
import XCTest

/// La codificación incremental (reutilizar referencias de lo que no cambió) no puede producir otra cosa que lo que
/// produce una codificación completa: mismos objetos, mismos hashes, también tras deshacer, rehacer y rechazos.
final class PixelArtIncrementalEncodingTests: XCTestCase {
    private func fullRef(_ state: PixelArtState) -> PxaObjectRef {
        var store = PxaObjectStore()
        return PixelArtStateCodec.encode(state, into: &store)
    }

    private func stroke(_ document: inout PixelArtDocument, layer: Int, frame: Int, seed: Int) throws {
        let layerID = document.state.layers[layer].id
        let frameID = document.state.frames[frame].id
        let writes = (0..<40).map { step in
            PixelWrite(x: (seed * 7 + step * 3) % 96, y: (seed * 13 + step) % 96, value: .free(PixelRGBA(UInt8(seed), UInt8(step), 9)))
        }
        try document.core.apply(PixelTransaction(label: "trazo", operationKind: "pencil", scope: .cel(layer: layerID, frame: frameID),
                                                 operations: [.writePixels(layer: layerID, frame: frameID, writes: writes)]))
    }

    private func sample() throws -> PixelArtDocument {
        var document = try PixelArtDocument(width: 96, height: 96)
        try document.core.apply(PixelTransaction(label: "capa", operationKind: "t", scope: .document(document.state),
                                                 operations: [.addLayer(PixelLayer(name: "Tinta"), at: 1)]))
        try document.core.apply(PixelTransaction(label: "fotograma", operationKind: "t", scope: .document(document.state),
                                                 operations: [.addFrame(PixelFrame(), at: 1)]))
        for seed in 0..<6 { try stroke(&document, layer: seed % 2, frame: seed % 2, seed: seed) }
        return document
    }

    func testEveryCommitMatchesAFullEncodingOfTheSameState() throws {
        var document = try PixelArtDocument(width: 96, height: 96)
        XCTAssertEqual(document.core.stateRef, fullRef(document.state))
        document = try sample()
        XCTAssertEqual(document.core.stateRef, fullRef(document.state))
    }

    func testCommitsAfterUndoRedoAndNavigationStillMatch() throws {
        var document = try sample()
        for _ in 0..<3 { try document.core.undo() }
        XCTAssertEqual(document.core.stateRef, fullRef(document.state))
        try stroke(&document, layer: 1, frame: 0, seed: 50)
        XCTAssertEqual(document.core.stateRef, fullRef(document.state), "una rama nueva tras deshacer")
        try document.core.undo()
        try document.core.redo()
        try stroke(&document, layer: 0, frame: 1, seed: 51)
        XCTAssertEqual(document.core.stateRef, fullRef(document.state))
        XCTAssertNoThrow(try PixelArtStateCodec.decode(document.core.stateRef, from: document.core.store))
    }

    func testARejectedCommitDoesNotPoisonTheNextOne() throws {
        var document = try sample()
        let layerID = document.state.layers[0].id
        try document.core.apply(PixelTransaction(label: "bloquear", operationKind: "t", scope: .document(document.state),
                                                 operations: [.setLayerProperty(layerID, .locked(true))]))
        let before = document.state
        let frameID = document.state.frames[0].id
        XCTAssertThrowsError(try document.core.apply(PixelTransaction(label: "editar bloqueada", operationKind: "pencil",
                                                                      scope: .cel(layer: layerID, frame: frameID),
                                                                      operations: [.writePixels(layer: layerID, frame: frameID,
                                                                                                writes: [
                                                                                                    PixelWrite(x: 1, y: 1,
                                                                                                               value: .free(PixelRGBA(1, 2,
                                                                                                                                      3)))
                                                                                                ])])))
        XCTAssertEqual(document.state, before)
        XCTAssertEqual(document.core.stateRef, fullRef(document.state))
        try stroke(&document, layer: 1, frame: 1, seed: 80)
        XCTAssertEqual(document.core.stateRef, fullRef(document.state))
    }

    func testTheFirstCommitAfterReopeningMatchesToo() throws {
        let document = try sample()
        var reopened = try PixelArtFile.read(try PixelArtFile.snapshot(of: document).data)
        try stroke(&reopened, layer: 0, frame: 0, seed: 90)
        XCTAssertEqual(reopened.core.stateRef, fullRef(reopened.state))
        try stroke(&reopened, layer: 0, frame: 0, seed: 91)
        XCTAssertEqual(reopened.core.stateRef, fullRef(reopened.state))
        let again = try PixelArtFile.read(try PixelArtFile.snapshot(of: reopened).data)
        XCTAssertEqual(again.state, reopened.state)
    }

    func testStructuralChangesReuseNothingWrongly() throws {
        var document = try sample()
        let frameID = document.state.frames[0].id
        try document.core.apply(PixelTransaction(label: "duplicar", operationKind: "t", scope: .document(document.state),
                                                 operations: [.duplicateFrame(frameID, newID: UUID(), at: 2)]))
        XCTAssertEqual(document.core.stateRef, fullRef(document.state))
        try document.core.apply(PixelTransaction(label: "tamaño", operationKind: "t", scope: .document(document.state),
                                                 operations: [.resizeCanvas(width: 70, height: 50, offsetX: -3, offsetY: 2)]))
        XCTAssertEqual(document.core.stateRef, fullRef(document.state))
        try document.core.apply(PixelTransaction(label: "borrar", operationKind: "t", scope: .document(document.state),
                                                 operations: [.deleteFrame(frameID)]))
        XCTAssertEqual(document.core.stateRef, fullRef(document.state))
    }
}
