import Foundation

extension PixelArtState {
    /// Reescribe los píxeles de las celdas del alcance. `transform` devuelve el valor nuevo o `nil`
    /// para conservar el actual; las celdas sin cambios no se tocan y los bloques que quedan vacíos
    /// se descartan.
    mutating func rewritePixels(in scope: PixelScope?, _ transform: (PixelValue) throws -> PixelValue?) rethrows {
        let layerIDs = layers.map(\.id).filter { scope?.layerIDs.contains($0) ?? true }
        for frameIndex in frames.indices where scope?.frameIDs.contains(frames[frameIndex].id) ?? true {
            for layerID in layerIDs {
                guard let cel = frames[frameIndex].cels[layerID] else { continue }
                var rewritten = cel
                for coord in cel.tiles.keys.sorted() {
                    guard var tile = rewritten.tiles[coord] else { continue }
                    var changed = false
                    for localY in 0..<PxaTile.side {
                        for localX in 0..<PxaTile.side {
                            let x = coord.x * PxaTile.side + localX
                            let y = coord.y * PxaTile.side + localY
                            guard x < width, y < height else { continue }
                            if let selection = scope?.selection, selection.contains(x: x, y: y) == false { continue }
                            let current = tile[localX, localY]
                            guard let replacement = try transform(current), replacement != current else { continue }
                            tile[localX, localY] = replacement
                            changed = true
                        }
                    }
                    if changed { rewritten.tiles[coord] = tile.isEmpty ? nil : tile }
                }
                if rewritten != cel { frames[frameIndex].cels[layerID] = rewritten.tiles.isEmpty ? nil : rewritten }
            }
        }
    }

    /// Color visible de un píxel antes de componer; los vinculados se resuelven contra la paleta.
    func resolvedColor(_ value: PixelValue) -> PixelRGBA? {
        switch value {
        case .empty: return nil
        case .free(let color): return color
        case .linked(let id): return palette.entry(id)?.color
        }
    }
}

extension PixelOperation {
    func applyPaletteOperation(_ state: inout PixelArtState, context: PixelOperationContext) throws {
        switch self {
        case .addPaletteEntry(let entry): try addEntry(entry, to: &state, context: context)
        case .editPaletteEntry(let id, let name, let color, let locked): try editEntry(id, name: name, color: color, locked: locked,
                                                                                       in: &state)
        case .reorderPalette(let order): try reorder(order, in: &state)
        case .replacePaletteColors(let colors): try replaceColors(colors, in: &state)
        case .adaptPixels(let table): try adapt(table, in: &state, scope: context.scope)
        case .linkExactMatches(let color, let entry): try link(color, to: entry, in: &state, scope: context.scope)
        case .unlinkPixels: unlink(in: &state, scope: context.scope)
        case .mergePaletteEntries(let keep, let remove): try merge(keep: keep, remove: remove, in: &state)
        case .deletePaletteEntry(let id, let removal): try delete(id, removal: removal, in: &state)
        case .recolorLinked(let source, let newEntry): try recolor(source: source, newEntry: newEntry, in: &state, context: context)
        default: break
        }
    }

    private func entryMissing(_ id: UInt32) -> PixelArtError { PixelArtError.invalid("paleta", "la entrada \(id) no existe") }

    private func addEntry(_ entry: PaletteEntry, to state: inout PixelArtState, context: PixelOperationContext) throws {
        guard context.isFreshEntryID(entry.id) else {
            throw PixelArtError.invalid("paleta", "el ID \(entry.id) no está reservado o ya se usó en este documento")
        }
        guard state.palette.entry(entry.id) == nil else { throw PixelArtError.invalid("paleta", "el ID \(entry.id) ya existe") }
        state.palette.entries.append(entry)
    }

    private func editEntry(_ id: UInt32, name: String?, color: PixelRGBA?, locked: Bool?, in state: inout PixelArtState) throws {
        guard let index = state.palette.entries.firstIndex(where: { $0.id == id }) else { throw entryMissing(id) }
        if let name { state.palette.entries[index].name = name }
        if let color { state.palette.entries[index].color = color }
        if let locked { state.palette.entries[index].locked = locked }
    }

    private func reorder(_ order: [UInt32], in state: inout PixelArtState) throws {
        guard Set(order) == state.palette.ids, order.count == state.palette.entries.count else {
            throw PixelArtError.invalid("paleta", "el nuevo orden debe contener exactamente las entradas actuales")
        }
        state.palette.entries = order.compactMap { state.palette.entry($0) }
    }

    private func replaceColors(_ colors: [UInt32: PixelRGBA], in state: inout PixelArtState) throws {
        for (id, color) in colors {
            guard let index = state.palette.entries.firstIndex(where: { $0.id == id }) else { throw entryMissing(id) }
            state.palette.entries[index].color = color
        }
    }

    /// Todo píxel del alcance debe tener correspondencia: una tabla incompleta no se completa en silencio.
    private func adapt(_ table: [PixelRGBA: PixelValue], in state: inout PixelArtState, scope: PixelScope) throws {
        let snapshot = state
        try state.rewritePixels(in: scope) { value in
            guard let color = snapshot.resolvedColor(value) else {
                if case .linked = value { throw PixelArtError.invalid("paleta", "un píxel vinculado apunta a una entrada inexistente") }
                return nil
            }
            guard let destination = table[color] else {
                throw PixelArtError.invalid("paleta",
                                            "falta la correspondencia para el color \(color.bytes.map(String.init).joined(separator: ","))")
            }
            if case .free(let free) = destination { return PixelValue.normalizedFree(free) }
            return destination
        }
    }

    private func link(_ color: PixelRGBA, to entry: UInt32, in state: inout PixelArtState, scope: PixelScope) throws {
        guard state.palette.entry(entry) != nil else { throw entryMissing(entry) }
        state.rewritePixels(in: scope) { value in
            if case .free(let current) = value, current == color { return .linked(entry) }
            return nil
        }
    }

    private func unlink(in state: inout PixelArtState, scope: PixelScope) {
        let table = state.palette.colorTable
        state.rewritePixels(in: scope) { value in
            guard case .linked(let id) = value, let color = table[id] else { return nil }
            return PixelValue.normalizedFree(color)
        }
    }

    private func reassign(_ removed: Set<UInt32>, to target: UInt32, in state: inout PixelArtState) {
        state.rewritePixels(in: nil) { value in
            if case .linked(let id) = value, removed.contains(id) { return .linked(target) }
            return nil
        }
    }

    private func merge(keep: UInt32, remove: [UInt32], in state: inout PixelArtState) throws {
        guard state.palette.entry(keep) != nil else { throw entryMissing(keep) }
        let removed = Set(remove)
        guard removed.contains(keep) == false, removed.isSubset(of: state.palette.ids) else {
            throw PixelArtError.invalid("paleta", "las entradas a fusionar no son válidas")
        }
        reassign(removed, to: keep, in: &state)
        state.palette.entries.removeAll { removed.contains($0.id) }
    }

    private func delete(_ id: UInt32, removal: PixelEntryRemoval, in state: inout PixelArtState) throws {
        guard let entry = state.palette.entry(id) else { throw entryMissing(id) }
        switch removal {
        case .reassign(let target):
            guard target != id, state.palette.entry(target) != nil else { throw entryMissing(target) }
            reassign([id], to: target, in: &state)
        case .unlink:
            state.rewritePixels(in: nil) { value in
                guard case .linked(let used) = value, used == id else { return nil }
                return PixelValue.normalizedFree(entry.color)
            }
        case .requireUnused:
            guard state.usedPaletteIDs.contains(id) == false else {
                throw PixelArtError.invalid("paleta", "la entrada \(id) tiene usos: elige un reemplazo o desvincular")
            }
        }
        state.palette.entries.removeAll { $0.id == id }
    }

    /// Recolorear solo una región que comparte un color: entrada nueva y reasignación de lo elegido;
    /// el ID original queda intacto para los píxeles de fuera (PXA-03 §7).
    private func recolor(source: UInt32, newEntry: PaletteEntry, in state: inout PixelArtState, context: PixelOperationContext) throws {
        guard state.palette.entry(source) != nil else { throw entryMissing(source) }
        try addEntry(newEntry, to: &state, context: context)
        state.rewritePixels(in: context.scope) { value in
            if case .linked(let id) = value, id == source { return .linked(newEntry.id) }
            return nil
        }
    }
}
