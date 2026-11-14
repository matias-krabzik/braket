import Foundation

struct PixelWrite: Equatable, Sendable {
    var x: Int
    var y: Int
    var value: PixelValue
}

enum PixelLayerProperty: Equatable, Sendable {
    case name(String)
    case visible(Bool)
    case locked(Bool)
    case alphaLocked(Bool)
    case opacity(Int)
}

/// Qué hacer con los usos de una entrada que se elimina (PXA-03 §8).
enum PixelEntryRemoval: Equatable, Sendable {
    case reassign(to: UInt32)
    case unlink
    case requireUnused
}

/// Operación del motor sobre un estado. Expresa IDs concretos, nunca «la capa seleccionada ahora»
/// (PXA-04 §1). No es código a ejecutar sino datos: el historial guarda estados completos y estas
/// operaciones solo describen cómo se llegó a ellos. Los bloqueos y el alcance no se comprueban aquí
/// sino al final, comparando estados (`PixelArtRules`), para que ninguna combinación de operaciones
/// pueda esquivarlos.
enum PixelOperation: Equatable, Sendable {
    // Píxeles
    case writePixels(layer: UUID, frame: UUID, writes: [PixelWrite])
    // Capas
    case addLayer(PixelLayer, at: Int)
    case setLayerProperty(UUID, PixelLayerProperty)
    case moveLayer(UUID, to: Int)
    case deleteLayer(UUID)
    case duplicateLayer(UUID, newID: UUID, name: String)
    // Fotogramas
    case addFrame(PixelFrame, at: Int)
    case duplicateFrame(UUID, newID: UUID, at: Int)
    case moveFrame(UUID, to: Int)
    case setFrameDuration(UUID, milliseconds: Int)
    case deleteFrame(UUID)
    // Paleta
    case addPaletteEntry(PaletteEntry)
    case editPaletteEntry(UInt32, name: String?, color: PixelRGBA?, locked: Bool?)
    case reorderPalette([UInt32])
    /// Sustituir los colores conservando identidades: ID → nuevo RGBA; lo omitido conserva su valor.
    case replacePaletteColors([UInt32: PixelRGBA])
    /// Adaptar píxeles del alcance a una tabla explícita color visible → destino.
    case adaptPixels([PixelRGBA: PixelValue])
    case linkExactMatches(color: PixelRGBA, entry: UInt32)
    case unlinkPixels
    case mergePaletteEntries(keep: UInt32, remove: [UInt32])
    case deletePaletteEntry(UInt32, removal: PixelEntryRemoval)
    /// Recolorear solo lo que hay en el alcance: entrada nueva y reasignación de los usos de `source`.
    case recolorLinked(source: UInt32, newEntry: PaletteEntry)
    // Documento y secuencias
    case resizeCanvas(width: Int, height: Int, offsetX: Int, offsetY: Int)
    case addSequence(PixelSequence)
    case editSequence(UUID, name: String?, frameIDs: [UUID]?, playback: PixelPlayback?, loops: Bool?)
    case deleteSequence(UUID)

    var isLockChange: Bool {
        switch self {
        case .setLayerProperty(_, .locked), .setLayerProperty(_, .alphaLocked): return true
        case .editPaletteEntry(_, _, _, let locked): return locked != nil
        default: return false
        }
    }
}

/// Qué necesita una operación del entorno que la rodea.
struct PixelOperationContext {
    var scope: PixelScope
    /// Un ID nuevo de paleta es válido si fue reservado y nunca se usó en ningún estado retenido.
    var isFreshEntryID: (UInt32) -> Bool
}

extension PixelOperation {
    func apply(to state: inout PixelArtState, context: PixelOperationContext) throws {
        switch self {
        case .writePixels(let layer, let frame, let writes): try applyWrites(&state, layer: layer, frame: frame, writes: writes)
        case .addLayer, .setLayerProperty, .moveLayer, .deleteLayer, .duplicateLayer: try applyLayerOperation(&state)
        case .addFrame, .duplicateFrame, .moveFrame, .setFrameDuration, .deleteFrame: try applyFrameOperation(&state)
        case .addSequence, .editSequence, .deleteSequence, .resizeCanvas: try applyDocumentOperation(&state)
        default: try applyPaletteOperation(&state, context: context)
        }
    }

    private func missing(_ what: String) -> PixelArtError { PixelArtError.invalid("operación", "\(what) no existe") }

    // MARK: Píxeles

    private func applyWrites(_ state: inout PixelArtState, layer: UUID, frame: UUID, writes: [PixelWrite]) throws {
        guard state.layerIndex(layer) != nil else { throw missing("la capa") }
        guard let frameIndex = state.frameIndex(frame) else { throw missing("el fotograma") }
        var cel = state.frames[frameIndex].cels[layer] ?? PixelCel()
        for write in writes {
            guard (0..<state.width).contains(write.x), (0..<state.height).contains(write.y) else {
                throw PixelArtError.invalid("operación", "el píxel (\(write.x), \(write.y)) cae fuera del lienzo")
            }
            cel.setPixel(x: write.x, y: write.y, to: write.value)
        }
        state.frames[frameIndex].cels[layer] = cel.tiles.isEmpty ? nil : cel
    }

    // MARK: Capas

    private func applyLayerOperation(_ state: inout PixelArtState) throws {
        switch self {
        case .addLayer(let layer, let index):
            guard (0...state.layers.count).contains(index) else { throw PixelArtError.invalid("operación", "posición de capa inválida") }
            guard state.layerIndex(layer.id) == nil else { throw PixelArtError.invalid("operación", "el ID de capa ya existe") }
            state.layers.insert(layer, at: index)
        case .setLayerProperty(let id, let property):
            guard let index = state.layerIndex(id) else { throw missing("la capa") }
            switch property {
            case .name(let name): state.layers[index].name = name
            case .visible(let value): state.layers[index].visible = value
            case .locked(let value): state.layers[index].locked = value
            case .alphaLocked(let value): state.layers[index].alphaLocked = value
            case .opacity(let value): state.layers[index].opacity = value
            }
        case .moveLayer(let id, let target):
            guard let index = state.layerIndex(id) else { throw missing("la capa") }
            guard (0..<state.layers.count).contains(target) else {
                throw PixelArtError.invalid("operación", "posición de capa inválida")
            }
            state.layers.insert(state.layers.remove(at: index), at: target)
        case .deleteLayer(let id):
            guard state.layerIndex(id) != nil else { throw missing("la capa") }
            guard state.layers.count > 1 else { throw PixelArtError.invalid("operación", "el documento necesita al menos una capa") }
            state.layers.removeAll { $0.id == id }
            for index in state.frames.indices { state.frames[index].cels[id] = nil }
        case .duplicateLayer(let id, let newID, let name):
            guard let index = state.layerIndex(id) else { throw missing("la capa") }
            guard state.layerIndex(newID) == nil else { throw PixelArtError.invalid("operación", "el ID de capa ya existe") }
            var copy = state.layers[index]
            copy.id = newID
            copy.name = name
            state.layers.insert(copy, at: index + 1)
            for frameIndex in state.frames.indices { state.frames[frameIndex].cels[newID] = state.frames[frameIndex].cels[id] }
        default:
            break
        }
    }

    // MARK: Fotogramas

    private func applyFrameOperation(_ state: inout PixelArtState) throws {
        switch self {
        case .addFrame(let frame, let index):
            guard (0...state.frames.count).contains(index)
                else { throw PixelArtError.invalid("operación", "posición de fotograma inválida") }
            guard state.frameIndex(frame.id) == nil else { throw PixelArtError.invalid("operación", "el ID de fotograma ya existe") }
            state.frames.insert(frame, at: index)
        case .duplicateFrame(let id, let newID, let target):
            guard let index = state.frameIndex(id) else { throw missing("el fotograma") }
            guard state.frameIndex(newID) == nil else { throw PixelArtError.invalid("operación", "el ID de fotograma ya existe") }
            guard (0...state.frames.count).contains(target)
                else { throw PixelArtError.invalid("operación", "posición de fotograma inválida") }
            var copy = state.frames[index]
            copy.id = newID
            state.frames.insert(copy, at: target)
        case .moveFrame(let id, let target):
            guard let index = state.frameIndex(id) else { throw missing("el fotograma") }
            guard (0..<state.frames.count).contains(target)
                else { throw PixelArtError.invalid("operación", "posición de fotograma inválida") }
            state.frames.insert(state.frames.remove(at: index), at: target)
        case .setFrameDuration(let id, let milliseconds):
            guard let index = state.frameIndex(id) else { throw missing("el fotograma") }
            state.frames[index].duration = milliseconds
        case .deleteFrame(let id):
            guard state.frameIndex(id) != nil else { throw missing("el fotograma") }
            guard state.frames.count > 1 else { throw PixelArtError.invalid("operación", "el documento necesita al menos un fotograma") }
            state.frames.removeAll { $0.id == id }
            // Retirar el fotograma de las secuencias en la misma transacción; una que quede vacía se elimina.
            for index in state.sequences.indices { state.sequences[index].frameIDs.removeAll { $0 == id } }
            state.sequences.removeAll { $0.frameIDs.isEmpty }
        default:
            break
        }
    }

    // MARK: Documento y secuencias

    private func applyDocumentOperation(_ state: inout PixelArtState) throws {
        switch self {
        case .addSequence(let sequence):
            guard state.sequences.contains(where: { $0.id == sequence.id }) == false else {
                throw PixelArtError.invalid("operación", "el ID de secuencia ya existe")
            }
            state.sequences.append(sequence)
        case .editSequence(let id, let name, let frameIDs, let playback, let loops):
            guard let index = state.sequences.firstIndex(where: { $0.id == id }) else { throw missing("la secuencia") }
            if let name { state.sequences[index].name = name }
            if let frameIDs { state.sequences[index].frameIDs = frameIDs }
            if let playback { state.sequences[index].playback = playback }
            if let loops { state.sequences[index].loops = loops }
        case .deleteSequence(let id):
            guard state.sequences.contains(where: { $0.id == id }) else { throw missing("la secuencia") }
            state.sequences.removeAll { $0.id == id }
        case .resizeCanvas(let width, let height, let offsetX, let offsetY):
            try resize(&state, width: width, height: height, offsetX: offsetX, offsetY: offsetY)
        default:
            break
        }
    }

    /// Recortar o ampliar: cada píxel se traslada por el desplazamiento y lo que cae fuera se descarta.
    private func resize(_ state: inout PixelArtState, width: Int, height: Int, offsetX: Int, offsetY: Int) throws {
        guard (1...PxaLimits.canvasAxis).contains(width), (1...PxaLimits.canvasAxis).contains(height),
              width * height <= PxaLimits.canvasPixels else {
            throw PixelArtError.limit("operación", "el lienzo debe medir 1–\(PxaLimits.canvasAxis) por eje")
        }
        let oldWidth = state.width
        let oldHeight = state.height
        for frameIndex in state.frames.indices {
            for (layerID, cel) in state.frames[frameIndex].cels {
                var moved = PixelCel()
                for (coord, tile) in cel.tiles {
                    for localY in 0..<PxaTile.side {
                        for localX in 0..<PxaTile.side {
                            let oldX = coord.x * PxaTile.side + localX
                            let oldY = coord.y * PxaTile.side + localY
                            let value = tile[localX, localY]
                            guard oldX < oldWidth, oldY < oldHeight, value != .empty else { continue }
                            let newX = oldX + offsetX
                            let newY = oldY + offsetY
                            guard (0..<width).contains(newX), (0..<height).contains(newY) else { continue }
                            moved.setPixel(x: newX, y: newY, to: value)
                        }
                    }
                }
                state.frames[frameIndex].cels[layerID] = moved.tiles.isEmpty ? nil : moved
            }
        }
        state.width = width
        state.height = height
    }
}
