import Foundation

/// Color sRGB de 8 bits por canal, sin premultiplicar (PXA-03 §3). Valor puro.
struct PixelRGBA: Hashable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var bytes: [UInt8] { [red, green, blue, alpha] }

    init?(bytes: [UInt8]) {
        guard bytes.count == 4 else { return nil }
        self.init(bytes[0], bytes[1], bytes[2], bytes[3])
    }

    /// Curva sRGB → lineal de un canal normalizado a 0…1.
    static func linear(_ channel: UInt8) -> Double {
        let value = Double(channel) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Curva lineal → sRGB, devuelto como entero con redondeo al más cercano y empates hacia arriba.
    static func encode(linear value: Double) -> UInt8 {
        let clamped = min(max(value, 0), 1)
        let encoded = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return UInt8(min(255, max(0, (encoded * 255 + 0.5).rounded(.down))))
    }

    /// Distancia de PXA-03 §6: suma de cuadrados de las diferencias de R·A, G·A, B·A y A,
    /// con RGB lineal. Es la métrica de la asignación automática a una paleta destino.
    func distance(to other: PixelRGBA) -> Double {
        let ownAlpha = Double(alpha) / 255
        let otherAlpha = Double(other.alpha) / 255
        let channels: [(Double, Double)] = [
            (Self.linear(red) * ownAlpha, Self.linear(other.red) * otherAlpha),
            (Self.linear(green) * ownAlpha, Self.linear(other.green) * otherAlpha),
            (Self.linear(blue) * ownAlpha, Self.linear(other.blue) * otherAlpha),
            (ownAlpha, otherAlpha)
        ]
        return channels.reduce(0) { total, pair in total + (pair.0 - pair.1) * (pair.0 - pair.1) }
    }
}

/// Un píxel es de una sola clase: vacío, libre o vinculado a una entrada de paleta (PXA-03 §1).
enum PixelValue: Hashable, Sendable {
    case empty
    case free(PixelRGBA)
    case linked(UInt32)

    /// Un color libre con alfa cero se guarda como vacío (PXA-01 §4).
    static func normalizedFree(_ color: PixelRGBA) -> PixelValue {
        color.alpha == 0 ? .empty : .free(color)
    }

    var linkedID: UInt32? {
        if case .linked(let id) = self { return id }
        return nil
    }
}

/// Entrada de paleta: el ID es estable y único; el nombre es opcional y no único (PXA-03 §1).
struct PaletteEntry: Equatable, Sendable {
    var id: UInt32
    var name = ""
    var color: PixelRGBA
    var locked = false
}

/// Paleta compartida por todo el estado. `entries` está en el orden de muestras; reordenarla
/// no cambia ninguna identidad (PXA-03 §1).
struct PixelPalette: Equatable, Sendable {
    var name = "Paleta"
    var entries: [PaletteEntry] = []

    func entry(_ id: UInt32) -> PaletteEntry? { entries.first { $0.id == id } }

    var ids: Set<UInt32> { Set(entries.map(\.id)) }

    /// Tabla ID → color para resolver muchos píxeles sin recorrer la lista cada vez.
    var colorTable: [UInt32: PixelRGBA] { Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.color) }) }
}

/// Reglas de texto de PXA-01 §6: nombres cortos sin controles ni caracteres bidi.
enum PixelArtText {
    private static let bidiControls: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                                    0x2066, 0x2067, 0x2068, 0x2069]

    static func validateName(_ text: String, section: String, allowEmpty: Bool = false) throws {
        if text.isEmpty {
            guard allowEmpty else { throw PixelArtError.invalid(section, "el nombre no puede estar vacío") }
            return
        }
        guard text.count <= PxaLimits.nameCharacters, text.utf8.count <= PxaLimits.nameBytes else {
            throw PixelArtError.limit(section, "el nombre supera \(PxaLimits.nameCharacters) caracteres o \(PxaLimits.nameBytes) bytes")
        }
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isControl = value < 0x20 || (0x7F...0x9F).contains(value)
            guard isControl == false, bidiControls.contains(value) == false else {
                throw PixelArtError.invalid(section, "el nombre contiene un carácter de control")
            }
        }
    }

    /// Mensajes y prompts admiten tabulador y saltos de línea, pero no otros controles ni NUL.
    static func validateMessage(_ text: String, section: String) throws {
        guard text.utf8.count <= PxaLimits.messageBytes else {
            throw PixelArtError.limit(section, "el texto supera \(PxaLimits.messageBytes) bytes")
        }
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isAllowed = value == 0x09 || value == 0x0A || value == 0x0D
            let isControl = value < 0x20 || (0x7F...0x9F).contains(value)
            guard isAllowed || isControl == false else {
                throw PixelArtError.invalid(section, "el texto contiene un carácter de control")
            }
        }
    }
}
