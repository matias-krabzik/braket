import Foundation

/// Un documento `.pxa` abierto: núcleo artístico con su historia, estado de edición, conversación con el
/// asistente y ajustes de exportación (PXA-01 §5). Es un valor que posee el actor del documento; la
/// interfaz lo envuelve, no lo copia por su cuenta.
struct PixelArtDocument: Sendable {
    /// Lo que se guardó en la última generación capturada. Sirve para decidir qué cambios están pendientes.
    struct SavedMark: Equatable, Sendable {
        var history: PixelHistory
        var editor: PixelEditorState
        var assistant: PixelAssistantState
        var exportPresets: [PixelExportPreset]
        var saveID: UUID
    }

    var core: PixelDocumentCore
    var editor: PixelEditorState
    var assistant: PixelAssistantState
    var exportPresets: [PixelExportPreset]
    var createdAt: Date
    /// ID del documento del que esta copia derivó; informativo.
    var copiedFrom: UUID?
    /// La historia es parcial: viene de una copia reducida o de una recuperación.
    var partialHistory: Bool
    /// Extensiones opcionales del manifiesto, preservadas sin interpretar.
    var extensions: [String: PixelArtJSON]
    /// Un archivo de una versión menor posterior se abre solo en lectura y nunca se reescribe desde aquí.
    private(set) var isReadOnly: Bool
    private(set) var saved: SavedMark?
    /// Avisos de la apertura: una miniatura descartada, referencias de la interfaz ajustadas.
    private(set) var warnings: [String]

    var documentID: UUID { core.documentID }
    var state: PixelArtState { core.state }

    /// Documento nuevo: lienzo transparente con una capa y un fotograma. Nunca se guardó.
    init(width: Int, height: Int) throws {
        let state = PixelArtState.blank(width: width, height: height)
        core = try PixelDocumentCore(state: state)
        editor = PixelEditorState.initial(for: state)
        assistant = PixelAssistantState()
        exportPresets = []
        createdAt = PxaDates.now()
        partialHistory = false
        extensions = [:]
        isReadOnly = false
        warnings = []
    }

    init(core: PixelDocumentCore, editor: PixelEditorState, assistant: PixelAssistantState, exportPresets: [PixelExportPreset],
         createdAt: Date, copiedFrom: UUID?, partialHistory: Bool, extensions: [String: PixelArtJSON], isReadOnly: Bool,
         warnings: [String]) {
        self.core = core
        self.editor = editor
        self.assistant = assistant
        self.exportPresets = exportPresets
        self.createdAt = createdAt
        self.copiedFrom = copiedFrom
        self.partialHistory = partialHistory
        self.extensions = extensions
        self.isReadOnly = isReadOnly
        self.warnings = warnings
    }

    // MARK: Cambios pendientes

    /// Hay historia o datos persistentes sin guardar: una revisión nueva, el cursor, una rama o la preferencia
    /// de Rehacer. Deshacer y volver al mismo punto sin tocar el grafo deja el documento limpio.
    var hasUnsavedArtisticChanges: Bool { saved.map { core.history != $0.history } ?? true }

    /// Mensajes o propuestas nuevos que aún no se guardaron. Esto sí cuenta para el aviso de cierre.
    var hasUnsavedAssistantContent: Bool {
        guard let saved else { return assistant.clearingDraft().isEmpty == false }
        return assistant.preparedForSave().clearingDraft() != saved.assistant.clearingDraft()
    }

    /// Zoom, selección, herramienta, borrador o ajustes de exportación: se recuperan localmente y se incluyen en
    /// el próximo guardado, pero un cambio de zoom aislado no provoca el diálogo de cierre.
    var hasUnsavedAuxiliaryChanges: Bool {
        guard let saved else { return true }
        return editor != saved.editor || exportPresets != saved.exportPresets || assistant.draft != saved.assistant.draft
    }

    /// Pérdida real de trabajo al cerrar: lo artístico y la conversación, no la vista.
    var needsClosePrompt: Bool { hasUnsavedArtisticChanges || hasUnsavedAssistantContent }

    var hasAnyUnsavedChange: Bool { hasUnsavedArtisticChanges || hasUnsavedAssistantContent || hasUnsavedAuxiliaryChanges }

    /// Registra como guardada solo la generación capturada: si se editó durante el guardado, los cambios
    /// posteriores siguen pendientes porque el documento actual ya no coincide con la marca.
    mutating func markSaved(_ mark: SavedMark) { saved = mark }

    mutating func addWarnings(_ messages: [String]) { warnings += messages }

    // MARK: Copias

    /// «Guardar una copia»: otro documento-ID con la misma historia; registra el ID de origen. Las propuestas
    /// listas pasan por la misma revalidación que al reabrir y adoptan el nuevo ID de forma explícita.
    func makeCopy() throws -> PixelArtDocument {
        let newCore = try PixelDocumentCore(documentID: UUID(), store: core.store, history: core.history,
                                            nextPaletteEntryID: core.nextPaletteEntryID, everUsedEntryIDs: core.everUsedEntryIDs)
        var copy = self
        copy.core = newCore
        copy.copiedFrom = documentID
        copy.saved = nil
        copy.assistant = assistant.preparedForSave().markedForRevalidation()
        copy.assistant.revalidate(core: newCore, adoptDocumentID: true)
        return copy
    }

    /// «Guardar copia con historial reducido…»: el estado actual con los últimos `ancestors` de su ruta. Se omiten
    /// ramas alternativas, revisiones anteriores y propuestas no aplicadas; los mensajes quedan como texto.
    func makeReducedCopy(keepingAncestors ancestors: Int?) throws -> PixelArtDocument {
        let (reduced, idMap) = try core.history.reduced(keepingAncestors: ancestors)
        let newCore = try PixelDocumentCore(documentID: UUID(), store: core.store, history: reduced,
                                            nextPaletteEntryID: core.nextPaletteEntryID, everUsedEntryIDs: core.everUsedEntryIDs)
        var copy = self
        copy.core = newCore
        copy.copiedFrom = documentID
        copy.partialHistory = true
        copy.saved = nil
        copy.assistant = assistant.preparedForSave().keepingAppliedProposals(retained: Set(idMap.keys), idMap: idMap)
        copy.assistant.revalidate(core: newCore, adoptDocumentID: true)
        return copy
    }
}

extension PixelAssistantState {
    func clearingDraft() -> PixelAssistantState {
        var copy = self
        try? copy.setDraft("")
        return copy
    }

    /// Las propuestas listas de un documento copiado pasan por revalidación, como al reabrir.
    func markedForRevalidation() -> PixelAssistantState {
        var copy = self
        copy.mutateProposals { proposals in
            for index in proposals.indices where proposals[index].status == .ready {
                proposals[index].needsRevalidation = true
                proposals[index].baseToken = nil
            }
        }
        return copy
    }

    /// Una copia reducida conserva solo las propuestas aplicadas cuya revisión sigue en la historia, con su
    /// referencia traducida; los mensajes que apuntaban a otras propuestas quedan como información textual.
    func keepingAppliedProposals(retained: Set<UUID>, idMap: [UUID: UUID]) -> PixelAssistantState {
        var copy = self
        copy.mutateProposals { proposals in
            proposals = proposals.compactMap { proposal in
                guard proposal.status == .applied, let applied = proposal.appliedRevisionID, retained.contains(applied) else { return nil }
                var kept = proposal
                kept.appliedRevisionID = idMap[applied]
                kept.baseRevisionID = idMap[proposal.baseRevisionID] ?? proposal.baseRevisionID
                kept.replaces = nil
                return kept
            }
        }
        let keptIDs = Set(copy.proposals.map(\.id))
        copy.mutateMessages { messages in
            for index in messages.indices
                where messages[index].proposalID.map(keptIDs.contains) == false { messages[index].proposalID = nil }
        }
        return copy
    }
}
