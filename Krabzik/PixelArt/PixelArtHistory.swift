import Foundation

/// Capa/fotograma activos y selección de edición. En una revisión se guarda antes y después de la
/// operación para poder deshacer un movimiento y seguir trabajando sobre la selección original (PXA-02 §4).
struct PixelFocus: Equatable, Sendable {
    var layerID: UUID?
    var frameID: UUID?
    /// `nil` es «sin selección»; una selección vacía explícita no permite pintar nada.
    var selection: PixelSelection?
}

/// Región rectangular afectada por una operación, en coordenadas del lienzo.
struct PixelRegion: Equatable, Sendable {
    var layerID: UUID
    var frameID: UUID
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

/// Resumen de lo que tocó una revisión. Ayuda a presentar cambios, pero no reemplaza la validación.
struct PixelAffected: Equatable, Sendable {
    var layers: [UUID] = []
    var frames: [UUID] = []
    var paletteEntries: [UInt32] = []
    var regions: [PixelRegion] = []
}

enum PixelRevisionSource: String, Sendable, CaseIterable {
    case manual, codex, system
    case imported = "import"
}

/// Nodo inmutable del árbol de historia. Resuelve directamente sus estados completos: deshacer no
/// reproduce comandos, así que una versión futura que no reconozca la etiqueta puede seguir navegando.
struct PixelRevision: Equatable, Sendable {
    var id = UUID()
    var parentID: UUID?
    /// Nulo únicamente en la raíz; en el resto debe coincidir con el estado final del padre.
    var beforeState: PxaObjectRef?
    var afterState: PxaObjectRef
    var operationKind: String
    var operationVersion = 1
    var label: String
    var source = PixelRevisionSource.manual
    var createdAt = PxaDates.now()
    var affected = PixelAffected()
    var assistantRecord: PxaObjectRef?
    var focusBefore = PixelFocus()
    var focusAfter = PixelFocus()
}

/// Marcador con nombre sobre una revisión.
struct PixelBookmark: Equatable, Sendable {
    var revisionID: UUID
    var name: String
}

/// Estado del presupuesto de historia (PXA-02 §7): se avisa al 80 % y se rechaza antes de superar el tope.
enum PixelHistoryBudget: Equatable, Sendable {
    case ok
    case warning(resource: String)
    case exceeded(resource: String)

    static func evaluate(revisions: Int, storageBytes: Int) -> PixelHistoryBudget {
        if revisions >= PxaLimits.revisions { return .exceeded(resource: "revisiones") }
        if storageBytes >= PxaLimits.uncompressedBytes { return .exceeded(resource: "almacenamiento") }
        if revisions * 5 >= PxaLimits.revisions * 4 { return .warning(resource: "revisiones") }
        if storageBytes >= PxaLimits.uncompressedBytes / 5 * 4 { return .warning(resource: "almacenamiento") }
        return .ok
    }
}

/// Árbol de revisiones con un cursor (PXA-02 §1 y §5). Es un valor y no conoce el almacén: solo
/// referencias. No hay fusiones ni ciclos; el orden causal sale de los padres, nunca de las fechas.
/// Lo posee el documento abierto, confinado a su actor.
struct PixelHistory: Equatable, Sendable {
    private(set) var revisions: [UUID: PixelRevision]
    private(set) var rootID: UUID
    private(set) var cursorID: UUID
    /// Hijo al que lleva Rehacer desde cada nodo que ya tuvo continuación.
    private(set) var preferredChild: [UUID: UUID] = [:]
    private(set) var bookmarks: [PixelBookmark] = []

    /// Historia nueva cuyo único nodo es el estado inicial del documento.
    init(initialState: PxaObjectRef, label: String = "Documento nuevo", source: PixelRevisionSource = .system,
         focus: PixelFocus = PixelFocus()) {
        let root = PixelRevision(parentID: nil, beforeState: nil, afterState: initialState, operationKind: "initial", label: label,
                                 source: source, focusAfter: focus)
        revisions = [root.id: root]
        rootID = root.id
        cursorID = root.id
    }

    /// Reconstrucción desde datos ya leídos. Rechaza IDs repetidos y valida el grafo completo, de modo
    /// que un `PixelHistory` que existe siempre tiene raíz, cursor y padres que existen.
    init(revisions list: [PixelRevision], rootID: UUID, cursorID: UUID, preferredChild: [UUID: UUID],
         bookmarks: [PixelBookmark]) throws {
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard byID.count == list.count else { throw PixelArtError.invalid("historial", "hay IDs de revisión repetidos") }
        self.revisions = byID
        self.rootID = rootID
        self.cursorID = cursorID
        self.preferredChild = preferredChild
        self.bookmarks = bookmarks
        try validateGraph()
    }

    /// Invariante: `init` valida el grafo y todas las mutaciones lo conservan, así que el cursor existe.
    var cursor: PixelRevision {
        guard let revision = revisions[cursorID] else { preconditionFailure("el cursor del historial apunta a una revisión inexistente") }
        return revision
    }
    var count: Int { revisions.count }
    var currentState: PxaObjectRef { cursor.afterState }
    var canUndo: Bool { cursor.parentID != nil }
    var canRedo: Bool { preferredChild[cursorID] != nil }

    func revision(_ id: UUID) -> PixelRevision? { revisions[id] }

    func children(of id: UUID) -> [PixelRevision] {
        revisions.values.filter { $0.parentID == id }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// Ruta de la raíz al cursor, en orden causal.
    var pathToCursor: [PixelRevision] { path(to: cursorID) }

    func path(to id: UUID) -> [PixelRevision] {
        var result: [PixelRevision] = []
        var next: UUID? = id
        var guardCount = 0
        while let current = next, let revision = revisions[current], guardCount <= revisions.count {
            result.append(revision)
            next = revision.parentID
            guardCount += 1
        }
        return result.reversed()
    }

    /// Continuaciones alternativas que se abandonaron: hijos de la ruta actual que no son la ruta preferida.
    /// Una rama abandonada nunca queda guardada pero inaccesible (PXA-02 §5).
    var otherBranches: [PixelRevision] {
        let onPath = Set(pathToCursor.map(\.id))
        var branches: [PixelRevision] = []
        for revision in revisions.values where onPath.contains(revision.id) == false {
            if let parent = revision.parentID, onPath.contains(parent) { branches.append(revision) }
        }
        return branches.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    // MARK: Avance

    /// Publica una revisión hija del cursor y la convierte en la continuación preferida. Se rechaza
    /// antes de confirmar si el presupuesto está agotado: nunca se borra historia para hacer lugar.
    @discardableResult
    mutating func commit(_ revision: PixelRevision, storageBytes: Int = 0) throws -> PixelRevision {
        if case .exceeded(let resource) = PixelHistoryBudget.evaluate(revisions: count, storageBytes: storageBytes) {
            throw PixelArtError(kind: .capacity, section: "historial",
                                cause: "se alcanzó el límite de \(resource); guarda una copia con historial reducido")
        }
        var node = revision
        node.createdAt = PxaDates.truncated(revision.createdAt)
        node.parentID = cursorID
        node.beforeState = cursor.afterState
        guard revisions[node.id] == nil else { throw PixelArtError.invalid("historial", "la revisión ya existe") }
        revisions[node.id] = node
        preferredChild[cursorID] = node.id
        cursorID = node.id
        return node
    }

    /// Mueve el cursor al padre. El nodo que se abandona queda como continuación preferida.
    mutating func undo() -> PixelRevision? {
        guard let parent = cursor.parentID else { return nil }
        let undone = cursor
        preferredChild[parent] = undone.id
        cursorID = parent
        return undone
    }

    mutating func redo() -> PixelRevision? {
        guard let next = preferredChild[cursorID], let revision = revisions[next] else { return nil }
        cursorID = next
        return revision
    }

    /// Restaura cualquier revisión retenida sin crear una nueva: actualiza el cursor y la ruta preferida
    /// de la raíz al destino. Las preferencias fuera de esa ruta se conservan.
    mutating func navigate(to id: UUID) throws {
        guard revisions[id] != nil else { throw PixelArtError.invalid("historial", "la revisión no existe") }
        let route = path(to: id)
        for (parent, child) in zip(route, route.dropFirst()) { preferredChild[parent.id] = child.id }
        cursorID = id
    }

    // MARK: Marcadores

    mutating func setBookmark(_ name: String, on id: UUID) throws {
        guard revisions[id] != nil else { throw PixelArtError.invalid("historial", "la revisión no existe") }
        try PixelArtText.validateName(name, section: "marcador")
        bookmarks.removeAll { $0.revisionID == id }
        bookmarks.append(PixelBookmark(revisionID: id, name: name))
    }

    mutating func removeBookmark(on id: UUID) { bookmarks.removeAll { $0.revisionID == id } }

    // MARK: Validación del grafo

    /// Comprueba el grafo sin mirar estados: un solo raíz, padres que existen, sin ciclos, estados
    /// previos que coinciden con el final del padre, cursor y preferencias coherentes (PXA-02 §1).
    func validateGraph() throws {
        let section = "historial"
        guard revisions.isEmpty == false, revisions.count <= PxaLimits.revisions else {
            throw PixelArtError.limit(section, "el historial debe tener entre 1 y \(PxaLimits.revisions) revisiones")
        }
        guard let root = revisions[rootID], root.parentID == nil, root.beforeState == nil else {
            throw PixelArtError.invalid(section, "la raíz no existe o tiene padre")
        }
        guard revisions[cursorID] != nil else { throw PixelArtError.invalid(section, "el cursor apunta a una revisión inexistente") }
        for revision in revisions.values {
            try PixelArtText.validateName(revision.label, section: section)
            try PixelArtText.validateName(revision.operationKind, section: section)
            guard revision.operationVersion >= 1 else { throw PixelArtError.invalid(section, "versión de operación inválida") }
            guard revision.id == rootID || revision.parentID != nil else {
                throw PixelArtError.invalid(section, "hay más de una raíz")
            }
            guard let parentID = revision.parentID else { continue }
            guard let parent = revisions[parentID] else { throw PixelArtError.invalid(section, "un padre no existe") }
            guard revision.beforeState == parent.afterState else {
                throw PixelArtError.invalid(section, "el estado previo de una revisión no coincide con el final de su padre")
            }
        }
        try validateAcyclic()
        for (parent, child) in preferredChild {
            guard revisions[child]?.parentID == parent else {
                throw PixelArtError.invalid(section, "una continuación preferida no es hija de su nodo")
            }
        }
        for bookmark in bookmarks {
            guard revisions[bookmark.revisionID] != nil else { throw PixelArtError.invalid(section,
                                                                                           "un marcador apunta a una revisión inexistente")
                                                                                           }
            try PixelArtText.validateName(bookmark.name, section: "marcador")
        }
    }

    private func validateAcyclic() throws {
        var verified = Set<UUID>([rootID])
        for start in revisions.keys {
            var walk: [UUID] = []
            var onWalk = Set<UUID>()
            var current: UUID? = start
            while let id = current, verified.contains(id) == false {
                guard onWalk.insert(id).inserted else { throw PixelArtError.invalid("historial", "hay un ciclo de padres") }
                walk.append(id)
                current = revisions[id]?.parentID
            }
            verified.formUnion(walk)
        }
    }

    // MARK: Copia reducida

    /// Historia parcial para «Guardar copia con historial reducido…» (PXA-02 §7). Conserva el estado
    /// actual con los últimos `ancestors` de su ruta (`nil` o 0 = solo el estado actual). La revisión más
    /// antigua conservada pasa a ser la raíz; se regeneran identidades de revisiones y padres para no
    /// mutar registros inmutables. Devuelve la correspondencia vieja → nueva identidad.
    func reduced(keepingAncestors ancestors: Int?) throws -> (history: PixelHistory, idMap: [UUID: UUID]) {
        let route = pathToCursor
        let keep = max(0, ancestors ?? 0)
        let kept = Array(route.suffix(keep + 1))
        var idMap: [UUID: UUID] = [:]
        var rebuilt: [PixelRevision] = []
        for (index, original) in kept.enumerated() {
            var copy = original
            copy.id = UUID()
            idMap[original.id] = copy.id
            copy.parentID = index == 0 ? nil : rebuilt[index - 1].id
            copy.beforeState = index == 0 ? nil : rebuilt[index - 1].afterState
            rebuilt.append(copy)
        }
        let newBookmarks = bookmarks.compactMap { mark in idMap[mark.revisionID].map { PixelBookmark(revisionID: $0, name: mark.name) } }
        guard let first = rebuilt.first, let last = rebuilt.last else { throw PixelArtError.invalid("historial", "no hay revisiones") }
        var preferred: [UUID: UUID] = [:]
        for (parent, child) in zip(rebuilt, rebuilt.dropFirst()) { preferred[parent.id] = child.id }
        let history = try PixelHistory(revisions: rebuilt, rootID: first.id, cursorID: last.id,
                                       preferredChild: preferred, bookmarks: newBookmarks)
        return (history, idMap)
    }
}
