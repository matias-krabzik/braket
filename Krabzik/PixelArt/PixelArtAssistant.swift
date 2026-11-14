import Foundation

enum PixelMessageRole: String, Sendable {
    case user, assistant, system
}

/// Mensaje de la conversación con el asistente. Texto plano: se muestra como dato, nunca como HTML ni como
/// instrucción. No guarda credenciales ni rutas absolutas (PXA-04 §6).
struct PixelAssistantMessage: Equatable, Sendable {
    var id = UUID()
    var role: PixelMessageRole
    var date = PxaDates.now()
    var text: String
    var proposalID: UUID?
}

enum PixelProposalStatus: String, Sendable {
    case preparing, ready, applied, discarded, failed, cancelled
    /// La base cambió: se conserva para comparar, pero no se puede aplicar.
    case stale
    /// Una tarea que estaba a medio ejecutar al cerrar: no tiene resultados aplicables.
    case interrupted
}

/// Cambio de una entrada de paleta dentro de una propuesta: la tabla que el usuario revisa antes de aplicar.
struct PixelPaletteChange: Equatable, Sendable {
    var id: UInt32
    var before: PaletteEntry?
    var after: PaletteEntry?
}

/// Propuesta aislada de Codex sobre una versión concreta del documento (PXA-04 §4). No toca el estado
/// artístico: aplicarla es una acción aparte que genera una revisión como cualquier edición manual.
struct PixelProposal: Equatable, Sendable {
    var id = UUID()
    var documentID: UUID
    var baseRevisionID: UUID
    var baseStateHash: String
    /// Alcance congelado al enviar el pedido: no cambia aunque el usuario mueva la selección.
    var scope: PixelScope
    var prompt: String
    var settings: [String: String] = [:]
    var summary = ""
    var proposedState: PxaObjectRef?
    /// Descripción corta de lo que hace cada operación, para inspección. No es código a ejecutar.
    var operationSummaries: [String] = []
    /// IDs de paleta reservados para esta propuesta; quedan consumidos aunque se cancele.
    var reservedEntryIDs: [UInt32] = []
    var paletteChanges: [PixelPaletteChange] = []
    var affected = PixelAffected()
    var estimatedObjects = 0
    var estimatedBytes = 0
    var status = PixelProposalStatus.preparing
    var model: String?
    var createdAt = PxaDates.now()
    var appliedRevisionID: UUID?
    /// Propuesta anterior que esta reemplaza al completarse («Pedir un ajuste»).
    var replaces: UUID?

    // Estado de ejecución: no se guarda en el archivo.
    var requestID: UUID?
    var baseToken: PixelBaseToken?
    /// Una propuesta reabierta empieza pendiente de revalidación; no se aplica por inferencia.
    var needsRevalidation = false
}

enum PixelApplyOutcome: Equatable, Sendable {
    case applied(PixelRevision)
    /// Aplicar dos veces el mismo ID devuelve la revisión ya creada; nunca duplica el cambio.
    case alreadyApplied(revisionID: UUID)
}

/// Conversación y propuestas de un documento (PXA-04 §4–§6). Es un valor que posee el documento abierto,
/// confinado a su actor. Hay como máximo una tarea ejecutándose y una propuesta pendiente por documento.
struct PixelAssistantState: Equatable, Sendable {
    private(set) var messages: [PixelAssistantMessage] = []
    private(set) var draft = ""
    private(set) var proposals: [PixelProposal] = []

    init() {}

    init(messages: [PixelAssistantMessage], draft: String, proposals: [PixelProposal]) {
        self.messages = messages
        self.draft = draft
        self.proposals = proposals
    }

    var isEmpty: Bool { messages.isEmpty && draft.isEmpty && proposals.isEmpty }

    func proposal(_ id: UUID) -> PixelProposal? { proposals.first { $0.id == id } }
    var running: PixelProposal? { proposals.first { $0.status == .preparing } }
    var pending: PixelProposal? { proposals.first { $0.status == .ready } }

    /// Bytes de texto que cuentan para el tope de PXA-01 §6: mensajes, borrador y texto de las propuestas.
    var textBytes: Int {
        messages.reduce(0) { $0 + $1.text.utf8.count } + draft.utf8.count
            + proposals.reduce(0) { $0 + $1.prompt.utf8.count + $1.summary.utf8.count }
    }

    // MARK: Mensajes

    /// Al alcanzar el tope no se truncan mensajes guardados: se impide agregar y se ofrece guardar una copia reducida.
    mutating func addMessage(_ message: PixelAssistantMessage) throws {
        try PixelArtText.validateMessage(message.text, section: "mensaje")
        guard textBytes + message.text.utf8.count <= PxaLimits.assistantTextBytes else {
            throw PixelArtError(kind: .capacity, section: "asistente",
                                cause: "la conversación alcanzó el límite de texto; guarda una copia con historial reducido")
        }
        messages.append(message)
    }

    mutating func setDraft(_ text: String) throws {
        try PixelArtText.validateMessage(text, section: "borrador")
        guard textBytes - draft.utf8.count + text.utf8.count <= PxaLimits.assistantTextBytes else {
            throw PixelArtError(kind: .capacity, section: "asistente", cause: "la conversación alcanzó el límite de texto")
        }
        draft = text
    }

    // MARK: Pedidos

    /// Congela base y alcance al enviar. Antes de un pedido independiente con una propuesta lista hay que
    /// aplicarla o descartarla; pedir un ajuste es otra cosa (`beginAdjustment`).
    mutating func begin(prompt: String, settings: [String: String] = [:], scope: PixelScope,
                        core: PixelDocumentCore) throws -> PixelProposal {
        try PixelArtText.validateMessage(prompt, section: "prompt")
        guard running == nil else {
            throw PixelArtError.invalid("asistente", "ya hay una tarea en ejecución en este documento")
        }
        guard pending == nil else {
            throw PixelArtError.invalid("asistente", "hay una propuesta lista: aplícala o descártala antes de un pedido nuevo")
        }
        return try register(prompt: prompt, settings: settings, scope: scope, core: core, replacing: nil)
    }

    /// Parte de la propuesta visible, mantiene su revisión original como base y la reemplaza al completarse.
    mutating func beginAdjustment(of id: UUID, prompt: String, core: PixelDocumentCore) throws -> PixelProposal {
        guard running == nil else { throw PixelArtError.invalid("asistente", "ya hay una tarea en ejecución en este documento") }
        guard let original = proposal(id), original.status == .ready, original.needsRevalidation == false else {
            throw PixelArtError.invalid("asistente", "solo se puede ajustar una propuesta lista y revalidada")
        }
        _ = try register(prompt: prompt, settings: original.settings, scope: original.scope, core: core, replacing: id)
        let last = proposals.count - 1
        proposals[last].baseRevisionID = original.baseRevisionID
        proposals[last].baseStateHash = original.baseStateHash
        proposals[last].baseToken = original.baseToken
        proposals[last].needsRevalidation = original.needsRevalidation
        proposals[last].reservedEntryIDs = original.reservedEntryIDs
        return proposals[last]
    }

    private mutating func register(prompt: String, settings: [String: String], scope: PixelScope, core: PixelDocumentCore,
                                   replacing: UUID?) throws -> PixelProposal {
        var proposal = PixelProposal(documentID: core.documentID, baseRevisionID: core.history.cursorID, baseStateHash: core.stateRef.hash,
                                     scope: scope, prompt: prompt, settings: settings)
        proposal.requestID = UUID()
        proposal.baseToken = core.token
        proposal.replaces = replacing
        proposals.append(proposal)
        return proposal
    }

    /// Reserva IDs de paleta para una propuesta. Quedan consumidos aunque se cancele; no cambian la imagen.
    mutating func reserveEntryIDs(for id: UUID, count: Int, core: inout PixelDocumentCore) throws -> [UInt32] {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { throw PixelArtError.invalid("asistente",
                                                                                                          "la propuesta no existe") }
        let ids = try core.reserveEntryIDs(count)
        proposals[index].reservedEntryIDs += ids
        return ids
    }

    // MARK: Resultado

    /// Registra el resultado del asistente si todavía es el pedido vigente. Una respuesta tardía —tras cancelar,
    /// reintentar o cerrar la pestaña— no puede publicar nada. El resultado se valida contra el estado base con
    /// las mismas reglas que una edición manual, así que lo que sale del alcance o toca algo bloqueado se rechaza.
    mutating func complete(requestID: UUID, proposed: PixelArtState, summary: String, operationSummaries: [String] = [],
                           model: String? = nil, core: inout PixelDocumentCore) throws {
        guard let index = proposals.firstIndex(where: { $0.requestID == requestID && $0.status == .preparing }) else {
            throw PixelArtError(kind: .stale, section: "asistente", cause: "la respuesta llegó tarde o el pedido fue cancelado")
        }
        try PixelArtText.validateMessage(summary, section: "resumen")
        var proposal = proposals[index]
        guard let token = proposal.baseToken, token == core.token else {
            proposals[index].status = .stale
            proposals[index].requestID = nil
            throw PixelArtError(kind: .stale, section: "asistente", cause: "el documento cambió mientras se preparaba la propuesta")
        }
        do {
            let analysis = try PixelProposalAnalysis.analyze(proposed, base: core, scope: proposal.scope,
                                                             reserved: Set(proposal.reservedEntryIDs))
            proposal.proposedState = try core.storeProposedState(proposed)
            proposal.paletteChanges = analysis.paletteChanges
            proposal.affected = analysis.affected
            proposal.estimatedObjects = analysis.newObjects
            proposal.estimatedBytes = analysis.newBytes
        } catch {
            proposals[index].status = .failed
            proposals[index].requestID = nil
            throw error
        }
        proposal.summary = summary
        proposal.operationSummaries = operationSummaries
        proposal.model = model
        proposal.status = .ready
        proposal.requestID = nil
        proposals[index] = proposal
        if let replaced = proposal.replaces { update(replaced) { $0.status = .discarded } }
    }

    mutating func fail(requestID: UUID) {
        guard let index = proposals.firstIndex(where: { $0.requestID == requestID && $0.status == .preparing }) else { return }
        proposals[index].status = .failed
        proposals[index].requestID = nil
    }

    /// Cancelar invalida el ID del pedido: ninguna respuesta posterior lo publica.
    mutating func cancel(_ id: UUID) {
        update(id) {
            guard $0.status == .preparing else { return }
            $0.status = .cancelled
            $0.requestID = nil
        }
    }

    /// Descartar no modifica el estado artístico; el mensaje y el resumen se conservan.
    mutating func discard(_ id: UUID) {
        update(id) { if $0.status == .ready || $0.status == .stale { $0.status = .discarded } }
    }

    // MARK: Obsolescencia y revalidación

    /// Una propuesta lista deja de ser aplicable en cuanto cambia la instancia, la revisión, el hash o la
    /// generación de edición. No hay fusión ni rebase: se conserva para comparar y se ofrece rehacer el pedido.
    mutating func markStaleIfBaseChanged(core: PixelDocumentCore) {
        for index in proposals.indices where proposals[index].status == .ready && proposals[index].needsRevalidation == false {
            if proposals[index].baseToken != core.token { proposals[index].status = .stale }
        }
    }

    /// Tras reabrir, una propuesta lista compara revisión, hash, alcance, IDs y límites con el documento cargado.
    /// Si coincide recibe el token de la nueva instancia y se puede aplicar; si no, queda obsoleta.
    /// `adoptDocumentID` cubre una copia con otro documento-ID: actualiza explícitamente su pertenencia.
    mutating func revalidate(core: PixelDocumentCore, adoptDocumentID: Bool = false) {
        for index in proposals.indices where proposals[index].status == .ready && proposals[index].needsRevalidation {
            let proposal = proposals[index]
            let sameDocument = proposal.documentID == core.documentID || adoptDocumentID
            let sameBase = proposal.baseRevisionID == core.history.cursorID && proposal.baseStateHash == core.stateRef.hash
            let layers = Set(core.state.layers.map(\.id))
            let frames = Set(core.state.frames.map(\.id))
            let scopeValid = proposal.scope.layerIDs.isSubset(of: layers) && proposal.scope.frameIDs.isSubset(of: frames)
            let analysis = proposal.proposedState.flatMap { ref in
                (try? core.cachedState(ref)).flatMap { try? PixelProposalAnalysis.analyze($0, base: core, scope: proposal.scope,
                                                                                          reserved: Set(proposal.reservedEntryIDs)) }
            }
            guard sameDocument, sameBase, scopeValid, analysis != nil else {
                proposals[index].status = .stale
                continue
            }
            proposals[index].baseToken = core.token
            proposals[index].needsRevalidation = false
            if adoptDocumentID { proposals[index].documentID = core.documentID }
        }
    }

    // MARK: Aplicar

    /// Genera una sola revisión con el registro de procedencia y marca la propuesta como aplicada.
    mutating func apply(_ id: UUID, to core: inout PixelDocumentCore) throws -> PixelApplyOutcome {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { throw PixelArtError.invalid("asistente",
                                                                                                          "la propuesta no existe") }
        let proposal = proposals[index]
        if proposal.status == .applied, let revisionID = proposal.appliedRevisionID { return .alreadyApplied(revisionID: revisionID) }
        guard proposal.status == .ready, proposal.needsRevalidation == false, let ref = proposal.proposedState,
              let token = proposal.baseToken else {
            throw PixelArtError(kind: .stale, section: "propuesta", cause: "la propuesta no está lista para aplicarse")
        }
        let proposed = try core.cachedState(ref)
        let record = core.storeAssistantRecord(fields: [
            "proposalID": .string(proposal.id.uuidString), "prompt": .string(proposal.prompt),
            "settings": .object(proposal.settings.mapValues { .string($0) }), "summary": .string(proposal.summary),
            "scope": .string(proposal.scope.kind.rawValue), "baseRevisionID": .string(proposal.baseRevisionID.uuidString),
            "model": proposal.model.map { .string($0) } ?? .null
        ])
        let transaction = PixelTransaction(label: "Aplicar propuesta de Codex", operationKind: "codexProposal", source: .codex,
                                           scope: proposal.scope, operations: [], base: token, assistantRecord: record)
        do {
            guard let revision = try core.applyProposedState(proposed, transaction: transaction) else {
                proposals[index].status = .stale
                throw PixelArtError(kind: .stale, section: "propuesta", cause: "la propuesta ya no cambia nada")
            }
            proposals[index].status = .applied
            proposals[index].appliedRevisionID = revision.id
            return .applied(revision)
        } catch let error as PixelArtError where error.kind == .stale {
            proposals[index].status = .stale
            throw error
        }
    }

    // MARK: Guardado

    /// Una tarea a medio ejecutar se guarda como interrumpida, sin resultados parciales aplicables. Al reabrir no
    /// se reanuda ni se envía ningún prompt. Las propuestas listas se guardan para revalidarse al abrir.
    func preparedForSave() -> PixelAssistantState {
        var copy = self
        for index in copy.proposals.indices {
            if copy.proposals[index].status == .preparing { copy.proposals[index].status = .interrupted }
            copy.proposals[index].requestID = nil
            // Lo de ejecución no se guarda: una propuesta lista se reabre pendiente de revalidación.
            copy.proposals[index].baseToken = nil
            copy.proposals[index].needsRevalidation = copy.proposals[index].status == .ready
        }
        return copy
    }

    /// Para transformaciones de conjunto de un documento copiado; no valida lo que cambia.
    mutating func mutateProposals(_ body: (inout [PixelProposal]) -> Void) { body(&proposals) }

    mutating func mutateMessages(_ body: (inout [PixelAssistantMessage]) -> Void) { body(&messages) }

    private mutating func update(_ id: UUID, _ change: (inout PixelProposal) -> Void) {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        change(&proposals[index])
    }
}

/// Qué cambia una propuesta respecto de su base, calculado comparando estados y no el resumen del asistente.
struct PixelProposalAnalysis: Equatable, Sendable {
    var affected: PixelAffected
    var paletteChanges: [PixelPaletteChange]
    var newObjects: Int
    var newBytes: Int

    static func analyze(_ proposed: PixelArtState, base core: PixelDocumentCore, scope: PixelScope,
                        reserved: Set<UInt32>) throws -> PixelProposalAnalysis {
        try proposed.validate()
        let diff = PixelStateDiff.between(core.state, proposed)
        guard diff.isEmpty == false else {
            throw PixelArtError.invalid("propuesta", "la propuesta no cambia nada: un cambio que solo toca vínculos también cuenta")
        }
        try PixelArtRules.check(base: core.state, result: proposed, diff: diff, scope: scope, source: .codex)
        for id in diff.addedEntries {
            guard reserved.contains(id), core.isFreshEntryID(id) else {
                throw PixelArtError.invalid("propuesta", "la entrada \(id) no está reservada para esta propuesta o ya se usó")
            }
        }
        var probe = core.store
        let before = probe.count
        let bytesBefore = probe.totalBytes
        _ = PixelArtStateCodec.encode(proposed, into: &probe)
        if case .exceeded(let resource) = PixelHistoryBudget.evaluate(revisions: core.history.count + 1, storageBytes: probe.totalBytes) {
            throw PixelArtError(kind: .capacity, section: "historial", cause: "aplicarla superaría el límite de \(resource)")
        }
        let changed = diff.editedEntries.keys.filter { diff.editedEntries[$0]?.color == true || diff.editedEntries[$0]?.name == true }
        let ids = Set(diff.addedEntries).union(diff.removedEntries).union(changed).sorted()
        let changes = ids.map { id in
            PixelPaletteChange(id: id, before: core.state.palette.entry(id), after: proposed.palette.entry(id))
        }
        return PixelProposalAnalysis(affected: diff.affected(base: core.state, result: proposed), paletteChanges: changes,
                                     newObjects: probe.count - before, newBytes: probe.totalBytes - bytesBefore)
    }
}
