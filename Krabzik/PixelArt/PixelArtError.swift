import Foundation

/// Error del motor de pixel art: dice **en qué sección** falló y **por qué**, como pide PXA-01 §6.
/// Es un valor sin estado, seguro de enviar entre hilos.
struct PixelArtError: Error, LocalizedError, Equatable, Sendable {
    enum Kind: String, Sendable {
        /// La estructura o un valor no cumple el contrato.
        case invalid
        /// Se superó un tope de PXA-01 §6.
        case limit
        /// Versión o capacidad que este lector no conoce.
        case unsupported
        /// Un hash, un tamaño o un CRC no coincide con lo declarado.
        case integrity
        /// El archivo cambió fuera de la app mientras se guardaba.
        case conflict
        /// Una capa o una entrada de paleta bloqueada protege lo que se quiso cambiar.
        case locked
        /// La operación sale del alcance explícito del pedido.
        case scope
        /// La base de una propuesta ya no es la actual.
        case stale
        /// No queda lugar: paleta llena, IDs agotados o presupuesto de historia.
        case capacity
    }

    var kind: Kind
    var section: String
    var cause: String

    var errorDescription: String? { "\(section): \(cause)" }

    static func invalid(_ section: String, _ cause: String) -> PixelArtError {
        PixelArtError(kind: .invalid, section: section, cause: cause)
    }

    static func limit(_ section: String, _ cause: String) -> PixelArtError {
        PixelArtError(kind: .limit, section: section, cause: cause)
    }

    static func integrity(_ section: String, _ cause: String) -> PixelArtError {
        PixelArtError(kind: .integrity, section: section, cause: cause)
    }

    static func unsupported(_ section: String, _ cause: String) -> PixelArtError {
        PixelArtError(kind: .unsupported, section: section, cause: cause)
    }
}

/// Topes iniciales de PXA-01 §6. Son decisiones de producto, no medidas de rendimiento:
/// si la validación con un corpus real obliga a moverlos, se actualiza el contrato primero.
enum PxaLimits {
    static let canvasAxis = 4_096
    static let canvasPixels = 16_777_216
    static let layers = 128
    static let frames = 1_024
    static let sequences = 256
    static let paletteEntries = 256
    static let tilesPerState = 65_536
    static let revisions = 100_000
    static let archiveBytes = 1 << 30
    static let uncompressedBytes = 2 << 30
    static let objects = 250_000
    static let jsonObjectBytes = 16 << 20
    static let manifestBytes = 1 << 20
    static let imageBytes = 32 << 20
    static let imageAxis = 4_096
    static let nameCharacters = 200
    static let nameBytes = 800
    static let messageBytes = 64 << 10
    static let assistantTextBytes = 16 << 20
    static let jsonDepth = 64
    static let paletteEntryIDMax: UInt32 = 4_294_967_294
    /// El contador de entradas llega a este valor cuando se agotó el rango.
    static let paletteCounterExhausted: UInt32 = 4_294_967_295
    static let minDurationMS = 1
    static let maxDurationMS = 60_000
    static let previewAxis = 512
}

/// Formato de las teselas: bloques de 32 × 32 píxeles de 5 bytes (PXA-01 §4).
enum PxaTile {
    static let side = 32
    static let pixelCount = side * side
    static let bytesPerPixel = 5
    static let byteCount = pixelCount * bytesPerPixel
    static let selectionByteCount = pixelCount / 8
}
