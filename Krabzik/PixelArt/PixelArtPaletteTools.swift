import Foundation

extension PixelArtState {
    /// Visita cada píxel no vacío del alcance con su capa. `scope == nil` recorre todo el documento.
    func forEachPixel(in scope: PixelScope?, _ body: (PixelLayer, PixelValue) -> Void) {
        for frame in frames where scope?.frameIDs.contains(frame.id) ?? true {
            for layer in layers where scope?.layerIDs.contains(layer.id) ?? true {
                guard let cel = frame.cels[layer.id] else { continue }
                for (coord, tile) in cel.tiles {
                    for localY in 0..<PxaTile.side {
                        for localX in 0..<PxaTile.side {
                            let x = coord.x * PxaTile.side + localX
                            let y = coord.y * PxaTile.side + localY
                            guard x < width, y < height else { continue }
                            if let selection = scope?.selection, selection.contains(x: x, y: y) == false { continue }
                            let value = tile[localX, localY]
                            if value != .empty { body(layer, value) }
                        }
                    }
                }
            }
        }
    }
}

/// Dónde se usa una entrada de paleta: para el preview del impacto antes de editarla (PXA-03 §4).
struct PixelPaletteUsage: Equatable, Sendable {
    var pixelCount = 0
    var layerIDs: Set<UUID> = []
    var frameIDs: Set<UUID> = []
}

/// Resultado de preparar la adaptación de píxeles a una paleta destino (PXA-03 §4 y §6).
struct PixelAdaptationPlan: Equatable, Sendable {
    /// Color visible de origen → destino. Es la tabla final: se registra tal cual y no se recalcula al rehacer.
    var table: [PixelRGBA: PixelValue] = [:]
    /// Píxeles cuyo aspecto cambia.
    var appearanceChanges = 0
    /// Píxeles que solo cambian de vínculo y conservan el aspecto.
    var linkOnlyChanges = 0
    /// Colores de alfa cero sin destino de alfa cero: pasarán a vacío y hay que confirmarlo.
    var becomesEmpty: Set<PixelRGBA> = []
    /// Algún destino cambia el alfa de un color de origen.
    var changesAlpha = false
}

/// Herramientas de paleta que alimentan los previews: se usa el mismo cálculo en el preview y al aplicar.
enum PixelPaletteTools {
    static func usages(in state: PixelArtState, scope: PixelScope? = nil) -> [UInt32: PixelPaletteUsage] {
        var result: [UInt32: PixelPaletteUsage] = [:]
        for frame in state.frames where scope?.frameIDs.contains(frame.id) ?? true {
            for layer in state.layers where scope?.layerIDs.contains(layer.id) ?? true {
                guard let cel = frame.cels[layer.id] else { continue }
                for (coord, tile) in cel.tiles {
                    for localY in 0..<PxaTile.side {
                        for localX in 0..<PxaTile.side {
                            let x = coord.x * PxaTile.side + localX
                            let y = coord.y * PxaTile.side + localY
                            guard x < state.width, y < state.height, case .linked(let id) = tile[localX, localY] else { continue }
                            if let selection = scope?.selection, selection.contains(x: x, y: y) == false { continue }
                            var usage = result[id] ?? PixelPaletteUsage()
                            usage.pixelCount += 1
                            usage.layerIDs.insert(layer.id)
                            usage.frameIDs.insert(frame.id)
                            result[id] = usage
                        }
                    }
                }
            }
        }
        return result
    }

    /// Colores RGBA exactos del alcance, sin el vacío, por frecuencia descendente y luego RGBA lexicográfico.
    /// Con más de 256 colores no descarta el resto como si fuera una extracción completa: pide reducir.
    static func extractPalette(from state: PixelArtState, scope: PixelScope? = nil) throws -> [PixelRGBA] {
        var counts: [PixelRGBA: Int] = [:]
        state.forEachPixel(in: scope) { _, value in
            if let color = state.resolvedColor(value), color.alpha > 0 { counts[color, default: 0] += 1 }
        }
        let ordered = counts.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.bytes.lexicographicallyPrecedes(rhs.key.bytes)
        }
        guard ordered.count <= PxaLimits.paletteEntries else {
            throw PixelArtError(kind: .capacity, section: "paleta",
                                cause: "hay \(ordered.count) colores y la paleta admite \(PxaLimits.paletteEntries): hay que reducir")
        }
        return ordered.map(\.key)
    }

    /// Asignación determinista de PXA-03 §6: para cada color de origen, la entrada destino de menor
    /// distancia RGBA; ante un empate de hasta 10⁻¹², gana el ID menor. Una correspondencia manual en
    /// `overrides` tiene prioridad. En una capa con alfa bloqueado solo valen destinos de igual alfa.
    static func automaticAdaptation(of state: PixelArtState, scope: PixelScope, targets: [PaletteEntry],
                                    overrides: [PixelRGBA: UInt32] = [:]) throws -> PixelAdaptationPlan {
        var sources = Set<PixelRGBA>()
        var alphaLockedSources = Set<PixelRGBA>()
        state.forEachPixel(in: scope) { layer, value in
            guard let color = state.resolvedColor(value) else { return }
            sources.insert(color)
            if layer.alphaLocked { alphaLockedSources.insert(color) }
        }
        let ordered = targets.sorted { $0.id < $1.id }
        var plan = PixelAdaptationPlan()
        for source in sources.sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) {
            let destination = try destination(for: source, among: ordered, override: overrides[source],
                                              alphaLocked: alphaLockedSources.contains(source))
            plan.table[source] = destination
            if destination == .empty { plan.becomesEmpty.insert(source) }
            let result = destinationColor(destination, targets: ordered)
            if (result?.alpha ?? 0) != source.alpha { plan.changesAlpha = true }
        }
        state.forEachPixel(in: scope) { _, value in
            guard let color = state.resolvedColor(value), let destination = plan.table[color] else { return }
            let newColor = destinationColor(destination, targets: ordered)
            if newColor != color {
                plan.appearanceChanges += 1
            } else if destination != value {
                plan.linkOnlyChanges += 1
            }
        }
        return plan
    }

    private static func destinationColor(_ value: PixelValue, targets: [PaletteEntry]) -> PixelRGBA? {
        switch value {
        case .empty: return nil
        case .free(let color): return color
        case .linked(let id): return targets.first { $0.id == id }?.color
        }
    }

    private static func destination(for source: PixelRGBA, among targets: [PaletteEntry], override: UInt32?,
                                    alphaLocked: Bool) throws -> PixelValue {
        if let override {
            guard let entry = targets.first(where: { $0.id == override }) else {
                throw PixelArtError.invalid("paleta",
                                            "la correspondencia manual apunta a la entrada \(override), que no está en el destino")
            }
            if alphaLocked, entry.color.alpha != source.alpha {
                throw PixelArtError(kind: .locked, section: "bloqueo", cause: "una capa con alfa bloqueado no admite cambiar el alfa")
            }
            return .linked(entry.id)
        }
        if source.alpha == 0 {
            if let transparent = targets.first(where: { $0.color.alpha == 0 }) { return .linked(transparent.id) }
            return .empty
        }
        let candidates = alphaLocked ? targets.filter { $0.color.alpha == source.alpha } : targets
        guard var best = candidates.first else {
            throw PixelArtError(kind: .locked, section: "bloqueo",
                                cause: alphaLocked ? "ninguna entrada destino conserva el alfa de una capa con alfa bloqueado"
                                    : "la paleta destino está vacía")
        }
        var bestDistance = source.distance(to: best.color)
        for candidate in candidates.dropFirst() {
            let distance = source.distance(to: candidate.color)
            if distance < bestDistance - 1e-12 {
                best = candidate
                bestDistance = distance
            }
        }
        return .linked(best.id)
    }
}
