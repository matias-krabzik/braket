import Foundation

/// Coordenada de un bloque de 32 × 32, alineada con el origen del lienzo.
struct TileCoord: Hashable, Comparable, Sendable {
    var x: Int
    var y: Int

    static func < (lhs: TileCoord, rhs: TileCoord) -> Bool { (lhs.y, lhs.x) < (rhs.y, rhs.x) }

    /// Clave textual `x,y` que se usa en los mapas JSON.
    var key: String { "\(x),\(y)" }

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    init?(key: String) {
        let parts = key.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let x = Int(parts[0]), let y = Int(parts[1]), "\(x),\(y)" == key else { return nil }
        self.init(x: x, y: y)
    }

    /// Bloque que contiene al píxel (`x`, `y`).
    init(containing x: Int, _ y: Int) {
        self.init(x: x / PxaTile.side, y: y / PxaTile.side)
    }
}

/// Bloque de 32 × 32 píxeles, 5 bytes por píxel por filas: una etiqueta y cuatro bytes de carga
/// (PXA-01 §4). Es un valor: copiarlo y editar la copia no toca el original.
struct PixelTile: Equatable, Sendable {
    private enum Tag {
        static let empty: UInt8 = 0
        static let free: UInt8 = 1
        static let linked: UInt8 = 2
    }

    private(set) var bytes: [UInt8]

    static let empty = PixelTile(bytes: [UInt8](repeating: 0, count: PxaTile.byteCount))

    init(bytes: [UInt8]) { self.bytes = bytes }

    var isEmpty: Bool { bytes.allSatisfy { $0 == 0 } }

    private static func offset(_ x: Int, _ y: Int) -> Int { (y * PxaTile.side + x) * PxaTile.bytesPerPixel }

    /// Lee el píxel local (`x`, `y`), con ambos en 0…31. El contenido ya fue validado al decodificar.
    subscript(x: Int, y: Int) -> PixelValue {
        get {
            let base = Self.offset(x, y)
            switch bytes[base] {
            case Tag.free: return .free(PixelRGBA(bytes[base + 1], bytes[base + 2], bytes[base + 3], bytes[base + 4]))
            case Tag.linked: return .linked(Self.id(bytes, at: base + 1))
            default: return .empty
            }
        }
        set {
            let base = Self.offset(x, y)
            switch newValue {
            case .empty:
                for index in 0..<PxaTile.bytesPerPixel { bytes[base + index] = 0 }
            case .free(let color) where color.alpha == 0:
                for index in 0..<PxaTile.bytesPerPixel { bytes[base + index] = 0 }
            case .free(let color):
                bytes.replaceSubrange(base..<base + PxaTile.bytesPerPixel, with: [Tag.free] + color.bytes)
            case .linked(let id):
                bytes.replaceSubrange(base..<base + PxaTile.bytesPerPixel, with: [Tag.linked] + Self.littleEndian(id))
            }
        }
    }

    private static func id(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func littleEndian(_ id: UInt32) -> [UInt8] {
        [UInt8(id & 0xFF), UInt8((id >> 8) & 0xFF), UInt8((id >> 16) & 0xFF), UInt8((id >> 24) & 0xFF)]
    }

    /// IDs de paleta que usa este bloque.
    var linkedIDs: Set<UInt32> {
        var result = Set<UInt32>()
        for index in 0..<PxaTile.pixelCount where bytes[index * PxaTile.bytesPerPixel] == Tag.linked {
            result.insert(Self.id(bytes, at: index * PxaTile.bytesPerPixel + 1))
        }
        return result
    }

    /// Valida el bloque contra el lienzo y la paleta. No sustituye nada por vacío: un bloque roto
    /// es un error (PXA-01 §4 y §6).
    static func validate(_ data: Data, at coord: TileCoord, width: Int, height: Int, paletteIDs: Set<UInt32>,
                         section: String) throws -> PixelTile {
        guard data.count == PxaTile.byteCount else {
            throw PixelArtError.invalid(section, "un bloque mide \(PxaTile.byteCount) bytes, no \(data.count)")
        }
        let bytes = [UInt8](data)
        for localY in 0..<PxaTile.side {
            for localX in 0..<PxaTile.side {
                let base = offset(localX, localY)
                let inside = coord.x * PxaTile.side + localX < width && coord.y * PxaTile.side + localY < height
                try validatePixel(bytes, at: base, inside: inside, paletteIDs: paletteIDs, section: section)
            }
        }
        return PixelTile(bytes: bytes)
    }

    private static func validatePixel(_ bytes: [UInt8], at base: Int, inside: Bool, paletteIDs: Set<UInt32>,
                                      section: String) throws {
        let payload = bytes[(base + 1)..<(base + PxaTile.bytesPerPixel)]
        if inside == false {
            guard bytes[base] == 0, payload.allSatisfy({ $0 == 0 }) else {
                throw PixelArtError.invalid(section, "hay datos fuera del lienzo en un bloque de borde")
            }
            return
        }
        switch bytes[base] {
        case Tag.empty:
            guard payload.allSatisfy({ $0 == 0 }) else { throw PixelArtError.invalid(section, "píxel vacío con datos") }
        case Tag.free:
            guard bytes[base + 4] != 0 else {
                throw PixelArtError.invalid(section, "color libre con alfa cero: debe guardarse como vacío")
            }
        case Tag.linked:
            let value = id(bytes, at: base + 1)
            guard value != 0, value <= PxaLimits.paletteEntryIDMax else {
                throw PixelArtError.invalid(section, "ID de paleta fuera de rango")
            }
            guard paletteIDs.contains(value) else {
                throw PixelArtError.invalid(section, "el ID de paleta \(value) no existe en la paleta")
            }
        default:
            throw PixelArtError.invalid(section, "etiqueta de píxel desconocida \(bytes[base])")
        }
    }
}

/// Máscara binaria de selección de un bloque: 128 bytes, filas consecutivas y el bit más
/// significativo primero (PXA-01 §5).
struct SelectionTile: Equatable, Sendable {
    private(set) var bytes: [UInt8]

    static let empty = SelectionTile(bytes: [UInt8](repeating: 0, count: PxaTile.selectionByteCount))
    static let full = SelectionTile(bytes: [UInt8](repeating: 0xFF, count: PxaTile.selectionByteCount))

    init(bytes: [UInt8]) { self.bytes = bytes }

    var isEmpty: Bool { bytes.allSatisfy { $0 == 0 } }

    subscript(x: Int, y: Int) -> Bool {
        get {
            let bit = y * PxaTile.side + x
            return bytes[bit / 8] & (0x80 >> UInt8(bit % 8)) != 0
        }
        set {
            let bit = y * PxaTile.side + x
            let mask = UInt8(0x80) >> UInt8(bit % 8)
            if newValue { bytes[bit / 8] |= mask } else { bytes[bit / 8] &= ~mask }
        }
    }

    static func validate(_ data: Data, at coord: TileCoord, width: Int, height: Int, section: String) throws -> SelectionTile {
        guard data.count == PxaTile.selectionByteCount else {
            throw PixelArtError.invalid(section, "una máscara mide \(PxaTile.selectionByteCount) bytes, no \(data.count)")
        }
        let tile = SelectionTile(bytes: [UInt8](data))
        for localY in 0..<PxaTile.side {
            for localX in 0..<PxaTile.side where tile[localX, localY] {
                let inside = coord.x * PxaTile.side + localX < width && coord.y * PxaTile.side + localY < height
                guard inside else { throw PixelArtError.invalid(section, "la selección sale del lienzo") }
            }
        }
        return tile
    }
}

/// Selección de píxeles: máscara dispersa por bloques. `nil` en el estado de edición significa
/// «sin selección»; un valor con cero bloques es una selección explícita vacía, que no permite
/// pintar ningún píxel (PXA-01 §5).
struct PixelSelection: Equatable, Sendable {
    var tiles: [TileCoord: SelectionTile] = [:]

    func contains(x: Int, y: Int) -> Bool {
        tiles[TileCoord(containing: x, y)]?[x % PxaTile.side, y % PxaTile.side] ?? false
    }

    var isEmpty: Bool { tiles.values.allSatisfy(\.isEmpty) }

    /// Rectángulo de píxeles, recortado al lienzo.
    static func rectangle(x: Int, y: Int, width: Int, height: Int, canvasWidth: Int, canvasHeight: Int) -> PixelSelection {
        var selection = PixelSelection()
        let right = min(x + width, canvasWidth)
        let bottom = min(y + height, canvasHeight)
        guard x < right, y < bottom, x >= 0, y >= 0 else { return selection }
        for pixelY in y..<bottom {
            for pixelX in x..<right {
                let coord = TileCoord(containing: pixelX, pixelY)
                var tile = selection.tiles[coord] ?? .empty
                tile[pixelX % PxaTile.side, pixelY % PxaTile.side] = true
                selection.tiles[coord] = tile
            }
        }
        return selection
    }
}
