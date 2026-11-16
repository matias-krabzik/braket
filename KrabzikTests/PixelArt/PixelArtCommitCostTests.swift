@testable import Krabzik
import XCTest

/// Costo de confirmar un trazo en documentos grandes (PXA-20 pide p95 ≤ 50 ms con hasta 10.000 posiciones).
/// Confirmar no puede recodificar el estado entero: el costo tiene que seguir al cambio, no al tamaño del documento.
final class PixelArtCommitCostTests: XCTestCase {
    /// Documento con muchos bloques repartidos en varias capas y fotogramas; cada uno con contenido distinto.
    static func denseDocument(side: Int = 512, layers: Int = 8, frames: Int = 8) throws -> PixelArtDocument {
        var document = try PixelArtDocument(width: side, height: side)
        for _ in 1..<layers {
            try document.core.apply(PixelTransaction(label: "capa", operationKind: "t", scope: .document(document.state),
                                                     operations: [.addLayer(PixelLayer(name: "Capa"), at: document.state.layers.count)]))
        }
        for _ in 1..<frames {
            try document.core.apply(PixelTransaction(label: "fotograma", operationKind: "t", scope: .document(document.state),
                                                     operations: [.addFrame(PixelFrame(), at: document.state.frames.count)]))
        }
        let tilesPerAxis = side / PxaTile.side
        for layer in 0..<layers {
            for frame in 0..<frames {
                let layerID = document.state.layers[layer].id
                let frameID = document.state.frames[frame].id
                let writes = (0..<tilesPerAxis * tilesPerAxis).map { index -> PixelWrite in
                    let tx = index % tilesPerAxis
                    let ty = index / tilesPerAxis
                    return PixelWrite(x: tx * PxaTile.side + layer, y: ty * PxaTile.side + frame,
                                      value: .free(PixelRGBA(UInt8(tx * 7 % 256), UInt8(ty * 5 % 256), UInt8(layer * 31 + frame))))
                }
                try document.core.apply(PixelTransaction(label: "relleno", operationKind: "t",
                                                         scope: .cel(layer: layerID, frame: frameID),
                                                         operations: [.writePixels(layer: layerID, frame: frameID, writes: writes)]))
            }
        }
        return document
    }

    /// Mediana de confirmar trazos de 200 píxeles sobre una celda de un documento ya cargado de bloques.
    private func medianCommit(_ document: inout PixelArtDocument, strokes: Int = 12) throws -> TimeInterval {
        let layerID = document.state.layers[0].id
        let frameID = document.state.frames[0].id
        var samples: [TimeInterval] = []
        for seed in 0..<strokes {
            let writes = (0..<200).map { step in
                PixelWrite(x: (seed * 11 + step * 3) % 512, y: (seed * 17 + step) % 512, value: .free(PixelRGBA(UInt8(seed), 40, 200)))
            }
            let start = Date()
            try document.core.apply(PixelTransaction(label: "trazo", operationKind: "pencil",
                                                     scope: .cel(layer: layerID, frame: frameID),
                                                     operations: [.writePixels(layer: layerID, frame: frameID, writes: writes)]))
            samples.append(Date().timeIntervalSince(start))
        }
        return samples.sorted()[samples.count / 2]
    }

    /// Confirmar un trazo solo recodifica lo que tocó: un fotograma, una celda y los bloques que el trazo pisa, no los
    /// 16.384 del documento. Es determinista (cuenta trabajo, no tiempo), así que vale igual en Debug y en Release.
    func testACommitReencodesOnlyWhatTheStrokeTouched() throws {
        var document = try Self.denseDocument()
        XCTAssertGreaterThan(document.state.tilePositionCount, 10_000)
        let layerID = document.state.layers[3].id
        let frameID = document.state.frames[5].id
        let writes = (0..<200).map { step in
            PixelWrite(x: (step * 3) % 512, y: (step * 5) % 512, value: .free(PixelRGBA(9, 40, 200)))
        }
        let touched = Set(writes.map { TileCoord(containing: $0.x, $0.y) }).count
        let before = document.core.encodingStatistics
        try document.core.apply(PixelTransaction(label: "trazo", operationKind: "pencil", scope: .cel(layer: layerID, frame: frameID),
                                                 operations: [.writePixels(layer: layerID, frame: frameID, writes: writes)]))
        let after = document.core.encodingStatistics
        XCTAssertEqual(after.frames - before.frames, 1)
        XCTAssertEqual(after.cels - before.cels, 1)
        XCTAssertLessThanOrEqual(after.tiles - before.tiles, touched)
        XCTAssertGreaterThan(after.tiles - before.tiles, 0)

        let again = document.core.encodingStatistics
        try document.core.apply(PixelTransaction(label: "otro", operationKind: "pencil", scope: .cel(layer: layerID, frame: frameID),
                                                 operations: [.writePixels(layer: layerID, frame: frameID, writes: writes)]))
        XCTAssertEqual(document.core.encodingStatistics, again, "un trazo que no cambia nada no codifica nada")
    }

    /// Antes de codificar de forma incremental, confirmar un trazo costaba 416 ms (Release) con 16.384 bloques, 16 veces
    /// lo de 1.024 bloques. Ahora cuesta ~7 ms y la razón es ~4: queda una parte lineal pequeña (copia del almacén y suma de
    /// bytes), sin hashear ni codificar lo que no cambió. En Debug esa parte lineal pesa mucho más (código sin optimizar),
    /// así que el tiempo solo se exige en Release; la prueba anterior comprueba el trabajo en cualquier configuración.
    func testCommitCostDoesNotGrowWithTheNumberOfTilesInTheDocument() throws {
        var small = try Self.denseDocument(layers: 2, frames: 2)
        var large = try Self.denseDocument(layers: 8, frames: 8)
        XCTAssertEqual(small.state.tilePositionCount * 16, large.state.tilePositionCount)
        _ = try medianCommit(&small, strokes: 4)
        _ = try medianCommit(&large, strokes: 4)
        let smallCost = try medianCommit(&small)
        let largeCost = try medianCommit(&large)
        print("[commit] \(small.state.tilePositionCount) bloques \(smallCost * 1000) ms · "
            + "\(large.state.tilePositionCount) bloques \(largeCost * 1000) ms")
        #if !DEBUG
        XCTAssertLessThan(largeCost, smallCost * 8, "el costo de confirmar crece con el tamaño del documento")
        #endif
    }
}
