import Foundation

/// Capa de un documento de pixel art. La lista de capas va de fondo a frente (PXA-01 §3).
struct PixelLayer: Equatable, Sendable {
    var id = UUID()
    var name: String
    var visible = true
    var locked = false
    /// Bloqueo de transparencia: conserva el alfa almacenado de cada posición (PXA-03 §7).
    var alphaLocked = false
    /// 0…255; multiplica el alfa solo al componer, no altera el píxel guardado.
    var opacity = 255
}

/// Contenido de una capa en un fotograma: mapa disperso de bloques. Un bloque ausente es transparente.
struct PixelCel: Equatable, Sendable {
    var tiles: [TileCoord: PixelTile] = [:]

    func pixel(x: Int, y: Int) -> PixelValue {
        tiles[TileCoord(containing: x, y)]?[x % PxaTile.side, y % PxaTile.side] ?? .empty
    }

    /// Escribe un píxel y descarta el bloque si queda vacío, para no guardar bloques sin contenido.
    mutating func setPixel(x: Int, y: Int, to value: PixelValue) {
        let coord = TileCoord(containing: x, y)
        var tile = tiles[coord] ?? .empty
        tile[x % PxaTile.side, y % PxaTile.side] = value
        tiles[coord] = tile.isEmpty ? nil : tile
    }
}

struct PixelFrame: Equatable, Sendable {
    var id = UUID()
    /// Milisegundos, 1…60.000. Es la autoridad; el FPS solo ayuda a calcularla.
    var duration = 100
    /// Capa → celda. Una intersección sin celda es transparente y no hereda del fotograma anterior.
    var cels: [UUID: PixelCel] = [:]
}

enum PixelPlayback: String, Sendable, CaseIterable {
    case forward, reverse, pingPong
}

struct PixelSequence: Equatable, Sendable {
    var id = UUID()
    var name: String
    var frameIDs: [UUID]
    var playback = PixelPlayback.forward
    var loops = true
}

/// Estado artístico completo e inmutable por valor: dimensiones, capas, fotogramas, paleta y
/// secuencias. Cada revisión del historial apunta a uno. Copiarlo comparte los bloques hasta que
/// alguno se edita (copy-on-write), así que guardar un estado por revisión no multiplica la memoria.
struct PixelArtState: Equatable, Sendable {
    var width: Int
    var height: Int
    var layers: [PixelLayer]
    var frames: [PixelFrame]
    var palette = PixelPalette()
    var sequences: [PixelSequence] = []

    /// Documento nuevo: lienzo transparente con una capa y un fotograma.
    static func blank(width: Int, height: Int) -> PixelArtState {
        PixelArtState(width: width, height: height, layers: [PixelLayer(name: "Capa 1")], frames: [PixelFrame()])
    }

    var tileColumns: Int { (width + PxaTile.side - 1) / PxaTile.side }
    var tileRows: Int { (height + PxaTile.side - 1) / PxaTile.side }

    func layerIndex(_ id: UUID) -> Int? { layers.firstIndex { $0.id == id } }
    func frameIndex(_ id: UUID) -> Int? { frames.firstIndex { $0.id == id } }

    func pixel(layer: UUID, frame: UUID, x: Int, y: Int) -> PixelValue {
        guard let index = frameIndex(frame) else { return .empty }
        return frames[index].cels[layer]?.pixel(x: x, y: y) ?? .empty
    }

    /// Cantidad de posiciones de celda con bloque, contando cada una aunque comparta hash (PXA-01 §6).
    var tilePositionCount: Int { frames.reduce(0) { $0 + $1.cels.values.reduce(0) { $0 + $1.tiles.count } } }

    /// Todos los IDs de paleta que usa algún píxel de este estado, en cualquier capa y fotograma.
    var usedPaletteIDs: Set<UInt32> {
        var used = Set<UInt32>()
        for frame in frames {
            for cel in frame.cels.values {
                for tile in cel.tiles.values { used.formUnion(tile.linkedIDs) }
            }
        }
        return used
    }

    /// Comprueba las invariantes del modelo (PXA-01 §3 y §6). `deepTiles` recorre además cada píxel;
    /// las operaciones que solo tocaron bloques ya validados pueden omitirlo.
    func validate(deepTiles: Bool = true) throws {
        try validateStructure()
        try validatePalette()
        try validateSequences()
        try validateCels(deepTiles: deepTiles)
    }

    private func validateStructure() throws {
        let section = "estado"
        guard (1...PxaLimits.canvasAxis).contains(width), (1...PxaLimits.canvasAxis).contains(height),
              width * height <= PxaLimits.canvasPixels else {
            throw PixelArtError.limit(section, "el lienzo debe medir 1–\(PxaLimits.canvasAxis) por eje y \(PxaLimits.canvasPixels) px")
        }
        guard (1...PxaLimits.layers).contains(layers.count) else {
            throw PixelArtError.limit(section, "debe haber entre 1 y \(PxaLimits.layers) capas")
        }
        guard (1...PxaLimits.frames).contains(frames.count) else {
            throw PixelArtError.limit(section, "debe haber entre 1 y \(PxaLimits.frames) fotogramas")
        }
        guard Set(layers.map(\.id)).count == layers.count, Set(frames.map(\.id)).count == frames.count else {
            throw PixelArtError.invalid(section, "hay IDs de capa o de fotograma repetidos")
        }
        for layer in layers {
            try PixelArtText.validateName(layer.name, section: "capa")
            guard (0...255).contains(layer.opacity) else { throw PixelArtError.limit("capa", "opacidad fuera de 0–255") }
        }
        for frame in frames {
            guard (PxaLimits.minDurationMS...PxaLimits.maxDurationMS).contains(frame.duration) else {
                throw PixelArtError.limit("fotograma", "la duración debe estar entre 1 y \(PxaLimits.maxDurationMS) ms")
            }
        }
        guard tilePositionCount <= PxaLimits.tilesPerState else {
            throw PixelArtError.limit(section, "más de \(PxaLimits.tilesPerState) bloques de píxeles")
        }
    }

    private func validatePalette() throws {
        let section = "paleta"
        try PixelArtText.validateName(palette.name, section: section)
        guard palette.entries.count <= PxaLimits.paletteEntries else {
            throw PixelArtError.limit(section, "más de \(PxaLimits.paletteEntries) entradas")
        }
        guard palette.ids.count == palette.entries.count else { throw PixelArtError.invalid(section, "hay IDs de entrada repetidos") }
        for entry in palette.entries {
            guard entry.id >= 1, entry.id <= PxaLimits.paletteEntryIDMax else {
                throw PixelArtError.invalid(section, "el ID de entrada \(entry.id) está fuera de rango")
            }
            try PixelArtText.validateName(entry.name, section: section, allowEmpty: true)
        }
    }

    private func validateSequences() throws {
        let section = "secuencias"
        guard sequences.count <= PxaLimits.sequences else {
            throw PixelArtError.limit(section, "más de \(PxaLimits.sequences) secuencias")
        }
        guard Set(sequences.map(\.id)).count == sequences.count else { throw PixelArtError.invalid(section, "IDs repetidos") }
        let frameIDs = Set(frames.map(\.id))
        for sequence in sequences {
            try PixelArtText.validateName(sequence.name, section: section)
            guard sequence.frameIDs.isEmpty == false else { throw PixelArtError.invalid(section, "una secuencia no puede estar vacía") }
            guard Set(sequence.frameIDs).count == sequence.frameIDs.count else {
                throw PixelArtError.invalid(section, "una secuencia repite un fotograma")
            }
            guard Set(sequence.frameIDs).isSubset(of: frameIDs) else {
                throw PixelArtError.invalid(section, "una secuencia apunta a un fotograma inexistente")
            }
        }
    }

    private func validateCels(deepTiles: Bool) throws {
        let layerIDs = Set(layers.map(\.id))
        let paletteIDs = palette.ids
        for frame in frames {
            for (layerID, cel) in frame.cels {
                guard layerIDs.contains(layerID) else { throw PixelArtError.invalid("celda", "apunta a una capa inexistente") }
                for (coord, tile) in cel.tiles {
                    guard coord.x >= 0, coord.y >= 0, coord.x < tileColumns, coord.y < tileRows else {
                        throw PixelArtError.invalid("celda", "bloque \(coord.key) fuera del lienzo")
                    }
                    guard tile.isEmpty == false else { throw PixelArtError.invalid("celda", "bloque vacío guardado en \(coord.key)") }
                    if deepTiles {
                        _ = try PixelTile.validate(Data(tile.bytes), at: coord, width: width, height: height,
                                                   paletteIDs: paletteIDs, section: "bloque \(coord.key)")
                    }
                }
            }
        }
    }
}

/// Imagen RGBA de 8 bits sin premultiplicar, en filas de arriba abajo.
struct PixelBitmap: Equatable, Sendable {
    var width: Int
    var height: Int
    var rgba: [UInt8]

    func pixel(x: Int, y: Int) -> PixelRGBA {
        let base = (y * width + x) * 4
        return PixelRGBA(rgba[base], rgba[base + 1], rgba[base + 2], rgba[base + 3])
    }
}

/// Composición de PXA-01 §3: de fondo a frente, source-over en sRGB lineal sobre RGB sin premultiplicar,
/// con la opacidad de capa multiplicando el alfa. Los colores vinculados se resuelven antes de componer.
/// El lienzo, la vista previa y la exportación deben usar este mismo camino.
enum PixelArtRenderer {
    private static let linearTable: [Double] = (0...255).map { PixelRGBA.linear(UInt8($0)) }

    /// `layerIDs` restringe qué capas se componen; `nil` usa las visibles. Una capa oculta solo
    /// se compone si se pide de forma explícita.
    static func render(_ state: PixelArtState, frame frameID: UUID, layerIDs: Set<UUID>? = nil) -> PixelBitmap {
        var output = PixelBitmap(width: state.width, height: state.height,
                                 rgba: [UInt8](repeating: 0, count: state.width * state.height * 4))
        guard let frame = state.frames.first(where: { $0.id == frameID }) else { return output }
        let table = state.palette.colorTable
        var accumulated = [Double](repeating: 0, count: state.width * state.height * 4)
        for layer in state.layers {
            let included = layerIDs.map { $0.contains(layer.id) } ?? layer.visible
            guard included, let cel = frame.cels[layer.id] else { continue }
            let opacity = Double(layer.opacity) / 255
            for (coord, tile) in cel.tiles {
                composite(tile, at: coord, opacity: opacity, table: table, state: state, into: &accumulated)
            }
        }
        for index in 0..<(state.width * state.height) {
            let alpha = accumulated[index * 4 + 3]
            guard alpha > 0 else { continue }
            for channel in 0..<3 { output.rgba[index * 4 + channel] = PixelRGBA.encode(linear: accumulated[index * 4 + channel] / alpha) }
            output.rgba[index * 4 + 3] = UInt8(min(255, (alpha * 255 + 0.5).rounded(.down)))
        }
        return output
    }

    /// `accumulated` guarda RGB lineal premultiplicado y alfa por píxel.
    private static func composite(_ tile: PixelTile, at coord: TileCoord, opacity: Double, table: [UInt32: PixelRGBA],
                                  state: PixelArtState, into accumulated: inout [Double]) {
        for localY in 0..<PxaTile.side {
            for localX in 0..<PxaTile.side {
                let x = coord.x * PxaTile.side + localX
                let y = coord.y * PxaTile.side + localY
                guard x < state.width, y < state.height else { continue }
                let color: PixelRGBA
                switch tile[localX, localY] {
                case .empty: continue
                case .free(let value): color = value
                case .linked(let id):
                    guard let resolved = table[id] else { continue }
                    color = resolved
                }
                let sourceAlpha = Double(color.alpha) / 255 * opacity
                guard sourceAlpha > 0 else { continue }
                let base = (y * state.width + x) * 4
                let remaining = 1 - sourceAlpha
                accumulated[base] = linearTable[Int(color.red)] * sourceAlpha + accumulated[base] * remaining
                accumulated[base + 1] = linearTable[Int(color.green)] * sourceAlpha + accumulated[base + 1] * remaining
                accumulated[base + 2] = linearTable[Int(color.blue)] * sourceAlpha + accumulated[base + 2] * remaining
                accumulated[base + 3] = sourceAlpha + accumulated[base + 3] * remaining
            }
        }
    }
}
