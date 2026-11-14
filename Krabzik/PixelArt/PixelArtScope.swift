import Foundation

/// Alcance explícito de un pedido (PXA-04 §2). Se resuelve a IDs concretos al crearse y no cambia
/// aunque el usuario mueva la selección o cambie de pestaña después. Es un valor.
struct PixelScope: Equatable, Sendable {
    enum Kind: String, Sendable {
        case selection, layer, frame, sequence, document
        /// Conjunto explícito de capas y fotogramas de una acción contextual sobre varias celdas.
        case custom
    }

    var kind: Kind
    var layerIDs: Set<UUID>
    var frameIDs: Set<UUID>
    /// Solo en «Selección»: máscara congelada. Una máscara vacía es un alcance vacío, no «todo el lienzo».
    var selection: PixelSelection?

    /// Máscara congelada con la capa y el fotograma activos.
    static func selection(_ mask: PixelSelection, layer: UUID, frame: UUID) -> PixelScope {
        PixelScope(kind: .selection, layerIDs: [layer], frameIDs: [frame], selection: mask)
    }

    /// «Capa · todos los fotogramas»: los fotogramas que existen al enviar.
    static func layer(_ id: UUID, in state: PixelArtState) -> PixelScope {
        PixelScope(kind: .layer, layerIDs: [id], frameIDs: Set(state.frames.map(\.id)))
    }

    static func frame(_ id: UUID, in state: PixelArtState) -> PixelScope {
        PixelScope(kind: .frame, layerIDs: Set(state.layers.map(\.id)), frameIDs: [id])
    }

    static func sequence(_ id: UUID, in state: PixelArtState) throws -> PixelScope {
        guard let sequence = state.sequences.first(where: { $0.id == id }) else {
            throw PixelArtError.invalid("alcance", "la secuencia no existe")
        }
        return PixelScope(kind: .sequence, layerIDs: Set(state.layers.map(\.id)), frameIDs: Set(sequence.frameIDs))
    }

    static func document(_ state: PixelArtState) -> PixelScope {
        PixelScope(kind: .document, layerIDs: Set(state.layers.map(\.id)), frameIDs: Set(state.frames.map(\.id)))
    }

    static func custom(layers: Set<UUID>, frames: Set<UUID>) -> PixelScope {
        PixelScope(kind: .custom, layerIDs: layers, frameIDs: frames)
    }

    /// Una acción manual sobre la celda activa: una capa, un fotograma.
    static func cel(layer: UUID, frame: UUID) -> PixelScope {
        PixelScope(kind: .custom, layerIDs: [layer], frameIDs: [frame])
    }

    var isDocument: Bool { kind == .document }

    func coversAllFrames(of state: PixelArtState) -> Bool { Set(state.frames.map(\.id)).isSubset(of: frameIDs) }

    func contains(layer: UUID, frame: UUID, x: Int, y: Int) -> Bool {
        guard layerIDs.contains(layer), frameIDs.contains(frame) else { return false }
        guard let selection else { return true }
        return selection.contains(x: x, y: y)
    }

    /// Resumen legible del alcance efectivo para el preview. No se promete «todas las capas»
    /// para luego omitir alguna: se presenta lo que realmente alcanza.
    func summary(in state: PixelArtState) -> String {
        switch kind {
        case .selection: return "Selección"
        case .layer: return "Capa · todos los fotogramas"
        case .frame: return "Fotograma · todas las capas"
        case .sequence: return "Secuencia · \(frameIDs.count) fotogramas"
        case .document: return "Documento"
        case .custom:
            return "Personalizado · \(layerIDs.count)/\(state.layers.count) capas, \(frameIDs.count)/\(state.frames.count) fotogramas"
        }
    }
}

/// Posición de una celda: una capa en un fotograma.
struct PixelCelKey: Hashable, Sendable {
    var layerID: UUID
    var frameID: UUID
}

/// Diferencias entre dos estados, calculadas comparando datos y no el resumen que diga el autor
/// de un cambio (PXA-04 §4). La usan las reglas de alcance y bloqueo, el preview y `affected`.
struct PixelStateDiff: Sendable {
    struct PaletteEdit: Sendable {
        var name = false
        var color = false
        var locked = false
    }

    var canvasChanged = false
    var addedLayers: Set<UUID> = []
    var removedLayers: Set<UUID> = []
    var layersReordered = false
    /// Capas existentes en ambos estados cuyas propiedades difieren, por propiedad.
    var changedLayerProperties: [UUID: Set<String>] = [:]
    var addedFrames: Set<UUID> = []
    var removedFrames: Set<UUID> = []
    var framesReordered = false
    var changedDurations: Set<UUID> = []
    var sequencesChanged = false
    var addedEntries: Set<UInt32> = []
    var removedEntries: Set<UInt32> = []
    var editedEntries: [UInt32: PaletteEdit] = [:]
    var paletteReordered = false
    var paletteRenamed = false
    /// Bloques distintos en celdas que existen en ambos estados (los de capas o fotogramas
    /// nuevos o eliminados se leen por esas listas).
    var changedTiles: [PixelCelKey: Set<TileCoord>] = [:]

    var hasStructuralChange: Bool {
        canvasChanged || addedLayers.isEmpty == false || removedLayers.isEmpty == false || layersReordered
            || addedFrames.isEmpty == false || removedFrames.isEmpty == false || framesReordered
            || changedDurations.isEmpty == false || sequencesChanged || paletteReordered || paletteRenamed
            || removedEntries.isEmpty == false || editedEntries.isEmpty == false
            || changedLayerProperties.isEmpty == false
    }

    var isEmpty: Bool { hasStructuralChange == false && addedEntries.isEmpty && changedTiles.isEmpty }

    static func between(_ base: PixelArtState, _ result: PixelArtState) -> PixelStateDiff {
        var diff = PixelStateDiff()
        diff.canvasChanged = base.width != result.width || base.height != result.height
        diff.compareLayers(base, result)
        diff.compareFrames(base, result)
        diff.sequencesChanged = base.sequences != result.sequences
        diff.comparePalette(base.palette, result.palette)
        diff.compareCels(base, result)
        return diff
    }

    private mutating func compareLayers(_ base: PixelArtState, _ result: PixelArtState) {
        let baseIDs = Set(base.layers.map(\.id))
        let resultIDs = Set(result.layers.map(\.id))
        addedLayers = resultIDs.subtracting(baseIDs)
        removedLayers = baseIDs.subtracting(resultIDs)
        let survivingBase = base.layers.map(\.id).filter(resultIDs.contains)
        let survivingResult = result.layers.map(\.id).filter(baseIDs.contains)
        layersReordered = survivingBase != survivingResult
        for layer in result.layers {
            guard let before = base.layers.first(where: { $0.id == layer.id }) else { continue }
            var changed = Set<String>()
            if before.name != layer.name { changed.insert("name") }
            if before.visible != layer.visible { changed.insert("visible") }
            if before.locked != layer.locked { changed.insert("locked") }
            if before.alphaLocked != layer.alphaLocked { changed.insert("alphaLocked") }
            if before.opacity != layer.opacity { changed.insert("opacity") }
            if changed.isEmpty == false { changedLayerProperties[layer.id] = changed }
        }
    }

    private mutating func compareFrames(_ base: PixelArtState, _ result: PixelArtState) {
        let baseIDs = Set(base.frames.map(\.id))
        let resultIDs = Set(result.frames.map(\.id))
        addedFrames = resultIDs.subtracting(baseIDs)
        removedFrames = baseIDs.subtracting(resultIDs)
        framesReordered = base.frames.map(\.id).filter(resultIDs.contains) != result.frames.map(\.id).filter(baseIDs.contains)
        for frame in result.frames {
            guard let before = base.frames.first(where: { $0.id == frame.id }), before.duration != frame.duration else { continue }
            changedDurations.insert(frame.id)
        }
    }

    private mutating func comparePalette(_ base: PixelPalette, _ result: PixelPalette) {
        let baseIDs = base.ids
        let resultIDs = result.ids
        addedEntries = resultIDs.subtracting(baseIDs)
        removedEntries = baseIDs.subtracting(resultIDs)
        paletteRenamed = base.name != result.name
        paletteReordered = base.entries.map(\.id).filter(resultIDs.contains) != result.entries.map(\.id).filter(baseIDs.contains)
        for entry in result.entries {
            guard let before = base.entry(entry.id) else { continue }
            let edit = PaletteEdit(name: before.name != entry.name, color: before.color != entry.color,
                                   locked: before.locked != entry.locked)
            if edit.name || edit.color || edit.locked { editedEntries[entry.id] = edit }
        }
    }

    private mutating func compareCels(_ base: PixelArtState, _ result: PixelArtState) {
        for resultFrame in result.frames {
            guard let baseFrame = base.frames.first(where: { $0.id == resultFrame.id }) else { continue }
            for layer in result.layers where base.layers.contains(where: { $0.id == layer.id }) {
                let before = baseFrame.cels[layer.id]?.tiles ?? [:]
                let after = resultFrame.cels[layer.id]?.tiles ?? [:]
                guard before != after else { continue }
                var changed = Set<TileCoord>()
                for coord in Set(before.keys).union(after.keys) where before[coord] != after[coord] { changed.insert(coord) }
                changedTiles[PixelCelKey(layerID: layer.id, frameID: resultFrame.id)] = changed
            }
        }
    }

    /// Cada píxel que cambió de valor almacenado en una celda presente en ambos estados.
    func forEachChangedPixel(base: PixelArtState, result: PixelArtState,
                             _ body: (PixelCelKey, Int, Int, PixelValue, PixelValue) throws -> Void) rethrows {
        for (key, coords) in changedTiles {
            let before = base.frames.first { $0.id == key.frameID }?.cels[key.layerID]
            let after = result.frames.first { $0.id == key.frameID }?.cels[key.layerID]
            for coord in coords {
                let beforeTile = before?.tiles[coord] ?? .empty
                let afterTile = after?.tiles[coord] ?? .empty
                for localY in 0..<PxaTile.side {
                    for localX in 0..<PxaTile.side where beforeTile[localX, localY] != afterTile[localX, localY] {
                        try body(key, coord.x * PxaTile.side + localX, coord.y * PxaTile.side + localY,
                                 beforeTile[localX, localY], afterTile[localX, localY])
                    }
                }
            }
        }
    }

    /// Resumen para `PixelRevision.affected`.
    func affected(result: PixelArtState) -> PixelAffected {
        var layers = Set(changedLayerProperties.keys).union(addedLayers).union(removedLayers)
        var frames = addedFrames.union(removedFrames).union(changedDurations)
        var regions: [PixelRegion] = []
        for (key, coords) in changedTiles {
            layers.insert(key.layerID)
            frames.insert(key.frameID)
            for coord in coords.sorted() {
                regions.append(PixelRegion(layerID: key.layerID, frameID: key.frameID, x: coord.x * PxaTile.side, y: coord.y * PxaTile.side,
                                           width: min(PxaTile.side, result.width - coord.x * PxaTile.side),
                                           height: min(PxaTile.side, result.height - coord.y * PxaTile.side)))
            }
        }
        let entries = addedEntries.union(removedEntries).union(editedEntries.keys).sorted()
        return PixelAffected(layers: layers.sorted { $0.uuidString < $1.uuidString },
                             frames: frames.sorted { $0.uuidString < $1.uuidString }, paletteEntries: entries,
                             regions: regions.sorted { ($0.layerID.uuidString, $0.frameID.uuidString, $0.y, $0.x)
                                 < ($1.layerID.uuidString, $1.frameID.uuidString, $1.y, $1.x) })
    }
}
