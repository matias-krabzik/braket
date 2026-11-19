import Foundation

/// Las acciones explícitas pueden cerrar resultados fijados; ejecutar el archivo solo
/// reemplaza los que no están fijados. Ninguna acción descarta una edición sin confirmar.
enum SQLResultTabAction: String, CaseIterable {
    case current = "Cerrar pestaña"
    case others = "Cerrar las demás"
    case left = "Cerrar a la izquierda"
    case right = "Cerrar a la derecha"
    case unpinned = "Cerrar sin fijar"
    case all = "Cerrar todas"
}

extension SQLExecution {
    private func tabIDs(_ action: SQLResultTabAction, relativeTo id: UUID?) -> Set<UUID> {
        let anchor = id.flatMap { target in results.firstIndex { $0.id == target } }
        switch action {
        case .current: return Set(results.filter { $0.id == id }.map(\.id))
        case .others:
            guard anchor != nil else { return [] }
            return Set(results.filter { $0.id != id }.map(\.id))
        case .left:
            guard let anchor else { return [] }
            return Set(results.prefix(anchor).map(\.id))
        case .right:
            guard let anchor else { return [] }
            return Set(results.dropFirst(anchor + 1).map(\.id))
        case .unpinned: return Set(results.filter { !pinned.contains($0.id) }.map(\.id))
        case .all: return Set(results.map(\.id))
        }
    }

    func canCloseTabs(_ action: SQLResultTabAction, relativeTo id: UUID? = nil) -> Bool {
        let ids = tabIDs(action, relativeTo: id)
        return !ids.isEmpty && results.filter { ids.contains($0.id) }.allSatisfy {
            !$0.isLoading && drafts[$0.id]?.sending != true
        }
    }

    @discardableResult
    func closeTabs(_ action: SQLResultTabAction, relativeTo id: UUID? = nil) -> Bool {
        let ids = tabIDs(action, relativeTo: id)
        let closing = results.filter { ids.contains($0.id) }
        guard closing.allSatisfy({ !$0.isLoading && drafts[$0.id]?.sending != true }) else { return false }
        for result in closing {
            if let draft = drafts[result.id], !draft.confirmDiscard() { return false }
        }
        // Resolver todas las confirmaciones antes de cambiar nada evita un cierre parcial al cancelar.
        let selected = selectedResult?.id
        let index = results.firstIndex { $0.id == selected } ?? 0
        let next = results.dropFirst(index + 1).first { !ids.contains($0.id) }?.id
            ?? results.prefix(index).last { !ids.contains($0.id) }?.id
        results.removeAll { ids.contains($0.id) }
        for id in ids { drafts.removeValue(forKey: id) }
        pinned.subtract(ids)
        if let targetResultID, ids.contains(targetResultID) { self.targetResultID = nil }
        if let selected, ids.contains(selected) { selectedResultID = next ?? results.first?.id }
        return true
    }
}
