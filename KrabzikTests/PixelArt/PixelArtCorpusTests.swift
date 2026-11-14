@testable import Krabzik
import XCTest

/// Costo real del formato en documentos representativos (PXA-01 «Riesgos»): el spec pide medir el costo de los
/// bloques de 32 × 32 y del historial antes de publicar 1.0. Los umbrales llevan el número medido al lado.
final class PixelArtCorpusTests: XCTestCase {
    private func stroke(_ document: inout PixelArtDocument, layer: Int, frame: Int, seed: Int, length: Int = 12) throws {
        let layerID = document.state.layers[layer].id
        let frameID = document.state.frames[frame].id
        let width = document.state.width
        let height = document.state.height
        let writes = (0..<length).map { step in
            PixelWrite(x: (seed * 7 + step * 3) % width, y: (seed * 13 + step) % height,
                       value: .free(PixelRGBA(UInt8((seed * 31) % 256), UInt8((step * 17) % 256), 90)))
        }
        try document.core.apply(PixelTransaction(label: "trazo \(seed)", operationKind: "pencil",
                                                 scope: .cel(layer: layerID, frame: frameID),
                                                 operations: [.writePixels(layer: layerID, frame: frameID, writes: writes)]))
    }

    private func measure<T>(_ body: () throws -> T) rethrows -> (T, TimeInterval) {
        let start = Date()
        let value = try body()
        return (value, Date().timeIntervalSince(start))
    }

    /// Sprite animado de 64 × 64: 3 capas, 8 fotogramas, 150 trazos.
    func testAnimatedSpriteWithAHundredFiftyStrokeHistory() throws {
        var document = try PixelArtDocument(width: 64, height: 64)
        for _ in 1..<3 {
            try document.core.apply(PixelTransaction(label: "capa", operationKind: "t", scope: .document(document.state),
                                                     operations: [.addLayer(PixelLayer(name: "Capa"), at: document.state.layers.count)]))
        }
        for _ in 1..<8 {
            try document.core.apply(PixelTransaction(label: "fotograma", operationKind: "t", scope: .document(document.state),
                                                     operations: [.addFrame(PixelFrame(), at: document.state.frames.count)]))
        }
        let (_, building) = try measure { for seed in 0..<150 { try stroke(&document, layer: seed % 3, frame: seed % 8, seed: seed) } }
        let (snapshot, saving) = try measure { try PixelArtFile.snapshot(of: document) }
        let (reopened, opening) = try measure { try PixelArtFile.read(snapshot.data) }
        XCTAssertEqual(reopened.state, document.state)
        print("[corpus sprite] 150 trazos \(building)s · guardar \(saving)s · abrir \(opening)s · archivo \(snapshot.data.count) B · "
            + "objetos \(snapshot.manifest.objectCount) · \(snapshot.data.count / 150) B por revisión")
        // Medido (2026-11-14, Debug): guardar 1,6 s y abrir 1,4 s; en Release 0,2 s y 0,13 s. El tope deja un margen
        // de diez veces para una máquina cargada: detecta un cambio de orden de magnitud, no una variación.
        XCTAssertLessThan(saving, 15)
        XCTAssertLessThan(opening, 15)
    }

    /// Ilustración de 512 × 512 con 4 capas y 60 trazos largos: más bloques por celda.
    func testIllustrationWithManyTiles() throws {
        var document = try PixelArtDocument(width: 512, height: 512)
        for _ in 1..<4 {
            try document.core.apply(PixelTransaction(label: "capa", operationKind: "t", scope: .document(document.state),
                                                     operations: [.addLayer(PixelLayer(name: "Capa"), at: document.state.layers.count)]))
        }
        let (_, building) = try measure { for seed in 0..<60 { try stroke(&document, layer: seed % 4, frame: 0, seed: seed, length: 400) } }
        let (snapshot, saving) = try measure { try PixelArtFile.snapshot(of: document) }
        let (_, opening) = try measure { try PixelArtFile.read(snapshot.data) }
        let tiles = document.state.tilePositionCount
        print("[corpus ilustración] 60 trazos \(building)s · guardar \(saving)s · abrir \(opening)s · "
            + "archivo \(snapshot.data.count) B · "
            + "bloques \(tiles) · objetos \(snapshot.manifest.objectCount)")
        // Medido (2026-11-14, Debug): guardar 5,9 s y abrir 5,4 s; en Release 0,37 s y 0,25 s. Cada confirmación de
        // trazo cuesta 130 ms en Debug y 17 ms en Release: reescribe el estado entero, así que crece con los bloques.
        XCTAssertLessThan(saving, 40)
        XCTAssertLessThan(opening, 40)
    }
}
