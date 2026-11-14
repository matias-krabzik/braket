import Foundation

/// Reglas de alcance y bloqueo de PXA-03 §7 y PXA-04 §1–§2. Comparan el estado base con el
/// resultado en lugar de confiar en lo que declaran las operaciones: así ninguna combinación,
/// manual o de Codex, puede esquivarlas. Los bloqueos se evalúan contra el estado base, de modo
/// que desbloquear y modificar en un mismo lote no los elude.
enum PixelArtRules {
    static func check(base: PixelArtState, result: PixelArtState, diff: PixelStateDiff, scope: PixelScope,
                      source: PixelRevisionSource) throws {
        try checkLockChanges(base: base, diff: diff, source: source)
        try checkStructure(base: base, result: result, diff: diff, scope: scope)
        try checkLockedLayers(base: base, result: result, diff: diff, source: source)
        try checkPixels(base: base, result: result, diff: diff, scope: scope)
        try checkPalette(base: base, result: result, diff: diff)
        try result.validate(deepTiles: false)
        try checkReferences(result: result, diff: diff)
    }

    private static func scopeError(_ cause: String) -> PixelArtError {
        PixelArtError(kind: .scope, section: "alcance", cause: cause)
    }

    private static func lockedError(_ cause: String) -> PixelArtError {
        PixelArtError(kind: .locked, section: "bloqueo", cause: cause)
    }

    // MARK: Bloqueos de Codex

    private static func checkLockChanges(base: PixelArtState, diff: PixelStateDiff, source: PixelRevisionSource) throws {
        guard source == .codex else { return }
        for properties in diff.changedLayerProperties.values where properties.contains("locked") || properties.contains("alphaLocked") {
            throw lockedError("Codex no puede cambiar los bloqueos de una capa")
        }
        for edit in diff.editedEntries.values where edit.locked {
            throw lockedError("Codex no puede cambiar el bloqueo de una entrada de paleta")
        }
    }

    // MARK: Estructura y alcance

    private static func checkStructure(base: PixelArtState, result: PixelArtState, diff: PixelStateDiff, scope: PixelScope) throws {
        let needsDocument = diff.canvasChanged || diff.removedLayers.isEmpty == false || diff.layersReordered
            || diff.addedFrames.isEmpty == false || diff.removedFrames.isEmpty == false || diff.framesReordered
            || diff.changedDurations.isEmpty == false || diff.sequencesChanged || diff.paletteReordered
            || diff.paletteRenamed || diff.removedEntries.isEmpty == false
            || diff.editedEntries.values.contains { $0.name || $0.color }
        if needsDocument, scope.isDocument == false {
            throw scopeError("el cambio afecta a todo el documento y el alcance elegido es «\(scope.summary(in: base))»")
        }
        for (layerID, properties) in diff.changedLayerProperties {
            guard scope.layerIDs.contains(layerID) else { throw scopeError("una propiedad de capa cambió fuera del alcance") }
            let affectsAllFrames = properties.contains("opacity") || properties.contains("visible")
            if affectsAllFrames, scope.isDocument == false, scope.coversAllFrames(of: base) == false {
                throw scopeError("cambiar opacidad o visibilidad afecta a todos los fotogramas de la capa")
            }
        }
        try checkAddedLayers(result: result, diff: diff, scope: scope)
    }

    /// Crear una capa dentro de un alcance de fotograma o de selección es válido solo si su contenido
    /// queda limitado a ese fotograma y a la máscara; la capa vacía no altera otros estados visuales.
    private static func checkAddedLayers(result: PixelArtState, diff: PixelStateDiff, scope: PixelScope) throws {
        guard scope.isDocument == false else { return }
        for layerID in diff.addedLayers {
            guard scope.kind == .frame || scope.kind == .selection || scope.kind == .custom else {
                throw scopeError("crear una capa no está permitido en un alcance de «\(scope.kind.rawValue)»")
            }
            for frame in result.frames {
                guard let cel = frame.cels[layerID] else { continue }
                guard scope.frameIDs.contains(frame.id) else { throw scopeError("la capa nueva tiene contenido fuera del alcance") }
                guard let selection = scope.selection else { continue }
                for (coord, tile) in cel.tiles {
                    for localY in 0..<PxaTile.side {
                        for localX in 0..<PxaTile.side where tile[localX, localY] != .empty {
                            let inside = selection.contains(x: coord.x * PxaTile.side + localX, y: coord.y * PxaTile.side + localY)
                            if inside == false { throw scopeError("la capa nueva sale de la selección") }
                        }
                    }
                }
            }
        }
    }

    // MARK: Capas bloqueadas

    private static func checkLockedLayers(base: PixelArtState, result: PixelArtState, diff: PixelStateDiff,
                                          source: PixelRevisionSource) throws {
        let locked = Set(base.layers.filter(\.locked).map(\.id))
        guard locked.isEmpty == false else { return }
        if diff.removedLayers.isDisjoint(with: locked) == false { throw lockedError("no se puede eliminar una capa bloqueada") }
        for (layerID, properties) in diff.changedLayerProperties where locked.contains(layerID) {
            if source == .codex { throw lockedError("Codex no puede modificar una capa bloqueada") }
            if properties.contains("opacity") { throw lockedError("no se puede cambiar la opacidad de una capa bloqueada") }
        }
        if diff.layersReordered { try checkRelativeOrder(base: base, result: result, locked: locked) }
        for frameID in diff.removedFrames {
            let frame = base.frames.first { $0.id == frameID }
            if locked
                .contains(where: { frame?.cels[$0] != nil }) { throw lockedError("el fotograma tiene contenido de una capa bloqueada") }
        }
    }

    /// Una capa bloqueada protege también su orden: no puede cambiar su posición relativa respecto de ninguna otra.
    private static func checkRelativeOrder(base: PixelArtState, result: PixelArtState, locked: Set<UUID>) throws {
        let survivors = Set(result.layers.map(\.id)).intersection(base.layers.map(\.id))
        let before = Dictionary(uniqueKeysWithValues: base.layers.map(\.id).filter(survivors.contains).enumerated().map { ($1, $0) })
        let after = Dictionary(uniqueKeysWithValues: result.layers.map(\.id).filter(survivors.contains).enumerated().map { ($1, $0) })
        for lockedID in locked.intersection(survivors) {
            for other in survivors where other != lockedID {
                let wasBelow = (before[lockedID] ?? 0) < (before[other] ?? 0)
                let isBelow = (after[lockedID] ?? 0) < (after[other] ?? 0)
                if wasBelow != isBelow { throw lockedError("una capa bloqueada no puede cambiar de posición relativa") }
            }
        }
    }

    // MARK: Píxeles

    private static func checkPixels(base: PixelArtState, result: PixelArtState, diff: PixelStateDiff, scope: PixelScope) throws {
        let layers = Dictionary(uniqueKeysWithValues: base.layers.map { ($0.id, $0) })
        try diff.forEachChangedPixel(base: base, result: result) { key, x, y, before, after in
            guard scope.contains(layer: key.layerID, frame: key.frameID, x: x, y: y) else {
                throw scopeError("un píxel cambió fuera del alcance «\(scope.summary(in: base))»")
            }
            guard let layer = layers[key.layerID] else { return }
            if layer.locked { throw lockedError("la capa «\(layer.name)» está bloqueada") }
            if layer.alphaLocked, alpha(of: before, in: base) != alpha(of: after, in: result) {
                throw lockedError("la capa «\(layer.name)» tiene bloqueado el alfa")
            }
        }
    }

    private static func alpha(of value: PixelValue, in state: PixelArtState) -> UInt8 {
        state.resolvedColor(value)?.alpha ?? 0
    }

    // MARK: Paleta

    private static func checkPalette(base: PixelArtState, result: PixelArtState, diff: PixelStateDiff) throws {
        for (id, edit) in diff.editedEntries {
            guard let entry = base.palette.entry(id) else { continue }
            if entry.locked, edit.name || edit.color { throw lockedError("la entrada de paleta «\(entry.name)» (\(id)) está bloqueada") }
        }
        for id in diff.removedEntries where base.palette.entry(id)?.locked == true {
            throw lockedError("no se puede eliminar una entrada de paleta bloqueada")
        }
        let touched = Set(diff.editedEntries.filter { $0.value.color }.keys).union(diff.removedEntries)
        guard touched.isEmpty == false else { return }
        let alphaChanged = Set(diff.editedEntries.compactMap { id, edit -> UInt32? in
            guard edit.color, base.palette.entry(id)?.color.alpha != result.palette.entry(id)?.color.alpha else { return nil }
            return id
        })
        for layer in base.layers where layer.locked || layer.alphaLocked {
            let used = linkedIDs(in: layer.id, of: base)
            if layer.locked, used.isDisjoint(with: touched) == false {
                throw lockedError("la capa bloqueada «\(layer.name)» usa una entrada que cambiaría")
            }
            if layer.alphaLocked, used.isDisjoint(with: alphaChanged) == false {
                throw lockedError("la capa «\(layer.name)» tiene bloqueado el alfa y usa una entrada cuyo alfa cambiaría")
            }
        }
    }

    private static func linkedIDs(in layerID: UUID, of state: PixelArtState) -> Set<UInt32> {
        var used = Set<UInt32>()
        for frame in state.frames {
            for tile in frame.cels[layerID].map({ Array($0.tiles.values) }) ?? [] { used.formUnion(tile.linkedIDs) }
        }
        return used
    }

    /// Ningún píxel puede quedar apuntando a una entrada que no existe en el estado resultante.
    private static func checkReferences(result: PixelArtState, diff: PixelStateDiff) throws {
        let ids = result.palette.ids
        if diff.removedEntries.isEmpty == false, result.usedPaletteIDs.isSubset(of: ids) == false {
            throw PixelArtError.invalid("paleta", "hay píxeles vinculados a una entrada eliminada")
        }
        for (key, coords) in diff.changedTiles {
            let cel = result.frames.first { $0.id == key.frameID }?.cels[key.layerID]
            for coord in coords {
                guard let tile = cel?.tiles[coord] else { continue }
                guard tile.linkedIDs.isSubset(of: ids) else {
                    throw PixelArtError.invalid("paleta", "un píxel apunta a una entrada de paleta que no existe")
                }
            }
        }
    }
}
