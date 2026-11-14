import Foundation

/// Identifica la versión exacta sobre la que se prepara un cambio: la misma instancia abierta, la misma
/// revisión, el mismo hash y la misma generación de edición (PXA-04 §5). Una propuesta solo se aplica
/// si todo coincide; no hay fusión ni rebase automático en 1.0.
struct PixelBaseToken: Equatable, Sendable {
    var instanceID: UUID
    var revisionID: UUID
    var stateHash: String
    var generation: Int
}

/// Una sola vía de modificación para herramientas manuales y para propuestas de Codex (PXA-04 §1).
struct PixelTransaction: Sendable {
    var label: String
    var operationKind: String
    var source = PixelRevisionSource.manual
    var scope: PixelScope
    var operations: [PixelOperation]
    /// `nil` aplica sobre el estado actual, como una edición manual; una propuesta trae su base.
    var base: PixelBaseToken?
    var focusBefore = PixelFocus()
    var focusAfter = PixelFocus()
    var assistantRecord: PxaObjectRef?
}

/// Qué restaurar en la interfaz al moverse por el historial.
struct PixelNavigation: Equatable, Sendable {
    var revisionID: UUID
    var focus: PixelFocus
}

/// Núcleo de un documento abierto: estado actual, historial persistente, almacén de objetos y asignador
/// de IDs de paleta. Es un valor sin hilos propios: lo posee y serializa el actor que abre el documento.
/// Toda modificación pasa por `apply`, que es atómico: si algo falla no queda un medio cambio.
struct PixelDocumentCore: Sendable {
    let documentID: UUID
    /// Identifica esta instancia abierta; copias en Finder con el mismo `documentID` son otra instancia.
    let instanceID: UUID
    private(set) var state: PixelArtState
    private(set) var stateRef: PxaObjectRef
    private(set) var history: PixelHistory
    private(set) var store: PxaObjectStore
    /// Próximo ID de entrada de paleta. Global al documento: no retrocede al deshacer.
    private(set) var nextPaletteEntryID: UInt32
    /// Sube al confirmar, deshacer, rehacer, navegar o recargar datos externos; no con zoom ni selección.
    private(set) var generation: Int
    /// IDs que aparecieron en algún estado retenido; nunca se reutilizan, ni en ramas ni en propuestas.
    private(set) var everUsedEntryIDs: Set<UInt32>
    private var recentStates: [(hash: String, state: PixelArtState)] = []
    private static let cacheSize = 8

    /// Documento nuevo con su estado inicial como raíz del historial.
    init(documentID: UUID = UUID(), state: PixelArtState, label: String = "Documento nuevo") throws {
        try state.validate()
        var store = PxaObjectStore()
        let ref = PixelArtStateCodec.encode(state, into: &store)
        self.documentID = documentID
        instanceID = UUID()
        self.state = state
        stateRef = ref
        self.store = store
        history = PixelHistory(initialState: ref, label: label)
        let ids = state.palette.ids
        everUsedEntryIDs = ids
        nextPaletteEntryID = (ids.max() ?? 0) + 1
        generation = 0
    }

    /// Reconstrucción desde un archivo ya validado. El contador no puede ser menor que ningún ID usado.
    init(documentID: UUID, store: PxaObjectStore, history: PixelHistory, nextPaletteEntryID: UInt32,
         everUsedEntryIDs: Set<UInt32>) throws {
        let ref = history.currentState
        self.documentID = documentID
        instanceID = UUID()
        self.store = store
        self.history = history
        stateRef = ref
        state = try PixelArtStateCodec.decode(ref, from: store)
        self.nextPaletteEntryID = nextPaletteEntryID
        self.everUsedEntryIDs = everUsedEntryIDs
        generation = 0
        guard (everUsedEntryIDs.max() ?? 0) < nextPaletteEntryID || nextPaletteEntryID == PxaLimits.paletteCounterExhausted else {
            throw PixelArtError.invalid("manifiesto", "el contador de paleta es menor que un ID ya usado")
        }
    }

    var token: PixelBaseToken {
        PixelBaseToken(instanceID: instanceID, revisionID: history.cursorID, stateHash: stateRef.hash, generation: generation)
    }

    // MARK: IDs de paleta

    /// Reserva IDs nuevos. Se consumen aunque la propuesta que los pidió se cancele: no tocan la imagen
    /// ni crean revisión. Ningún modelo elige IDs ya usados como si fueran nuevos.
    mutating func reserveEntryIDs(_ count: Int) throws -> [UInt32] {
        guard count >= 0, UInt64(nextPaletteEntryID) + UInt64(count) <= UInt64(PxaLimits.paletteCounterExhausted) else {
            throw PixelArtError(kind: .capacity, section: "paleta", cause: "se agotó el rango de IDs de entrada de paleta")
        }
        let ids = (0..<count).map { nextPaletteEntryID + UInt32($0) }
        nextPaletteEntryID += UInt32(count)
        return ids
    }

    func isFreshEntryID(_ id: UInt32) -> Bool {
        id >= 1 && id < nextPaletteEntryID && everUsedEntryIDs.contains(id) == false
    }

    // MARK: Aplicar

    /// Valida y publica una transacción como una sola revisión. Devuelve `nil` si no cambia nada
    /// artístico: no se crean revisiones vacías. Cualquier error deja el documento intacto.
    @discardableResult
    mutating func apply(_ transaction: PixelTransaction) throws -> PixelRevision? {
        if let base = transaction.base, base != token {
            throw PixelArtError(kind: .stale, section: "propuesta", cause: "el documento cambió desde que se preparó el cambio")
        }
        if case .exceeded(let resource) = PixelHistoryBudget.evaluate(revisions: history.count, storageBytes: store.totalBytes) {
            throw PixelArtError(kind: .capacity, section: "historial", cause: "se alcanzó el límite de \(resource)")
        }
        guard transaction.operations.isEmpty == false else { return nil }
        let nextID = nextPaletteEntryID
        let used = everUsedEntryIDs
        let context = PixelOperationContext(scope: transaction.scope,
                                            isFreshEntryID: { id in id >= 1 && id < nextID && used.contains(id) == false })
        var working = state
        for operation in transaction.operations { try operation.apply(to: &working, context: context) }
        let diff = PixelStateDiff.between(state, working)
        guard diff.isEmpty == false else { return nil }
        try PixelArtRules.check(base: state, result: working, diff: diff, scope: transaction.scope, source: transaction.source)

        var newStore = store
        let ref = PixelArtStateCodec.encode(working, into: &newStore)
        var newHistory = history
        var revision = PixelRevision(afterState: ref, operationKind: transaction.operationKind, label: transaction.label,
                                     source: transaction.source, affected: diff.affected(result: working),
                                     assistantRecord: transaction.assistantRecord, focusBefore: transaction.focusBefore,
                                     focusAfter: transaction.focusAfter)
        revision = try newHistory.commit(revision, storageBytes: newStore.totalBytes)
        remember(state, hash: stateRef.hash)
        state = working
        stateRef = ref
        store = newStore
        history = newHistory
        everUsedEntryIDs.formUnion(working.palette.ids)
        generation += 1
        return revision
    }

    // MARK: Navegar

    @discardableResult
    mutating func undo() throws -> PixelNavigation? {
        var moved = history
        guard let undone = moved.undo(), let before = undone.beforeState else { return nil }
        try restore(before, history: moved)
        return PixelNavigation(revisionID: moved.cursorID, focus: undone.focusBefore)
    }

    @discardableResult
    mutating func redo() throws -> PixelNavigation? {
        var moved = history
        guard let redone = moved.redo() else { return nil }
        try restore(redone.afterState, history: moved)
        return PixelNavigation(revisionID: redone.id, focus: redone.focusAfter)
    }

    /// Restaura cualquier revisión retenida sin crear una nueva.
    @discardableResult
    mutating func navigate(to id: UUID) throws -> PixelNavigation {
        var moved = history
        try moved.navigate(to: id)
        try restore(moved.cursor.afterState, history: moved)
        return PixelNavigation(revisionID: id, focus: moved.cursor.focusAfter)
    }

    /// Un cambio externo recargado cuenta como edición: invalida cualquier propuesta pendiente.
    mutating func noteExternalReload() { generation += 1 }

    private mutating func restore(_ ref: PxaObjectRef, history newHistory: PixelHistory) throws {
        let restored = try cachedState(ref)
        remember(state, hash: stateRef.hash)
        state = restored
        stateRef = ref
        history = newHistory
        generation += 1
    }

    // MARK: Caché de estados

    /// Estado de una referencia, decodificado y verificado. Una pequeña caché evita decodificar de nuevo
    /// el estado al que se vuelve una y otra vez con deshacer y rehacer.
    func cachedState(_ ref: PxaObjectRef) throws -> PixelArtState {
        if let hit = recentStates.first(where: { $0.hash == ref.hash }) { return hit.state }
        return try PixelArtStateCodec.decode(ref, from: store)
    }

    private mutating func remember(_ value: PixelArtState, hash: String) {
        recentStates.removeAll { $0.hash == hash }
        recentStates.insert((hash, value), at: 0)
        if recentStates.count > Self.cacheSize { recentStates.removeLast() }
    }
}
