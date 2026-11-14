import Foundation

/// Propuestas, conversación y registros de procedencia como objetos del almacén (PXA-04 §6).
enum PixelAssistantCodec {
    // MARK: Alcance

    private static func encode(_ scope: PixelScope, into store: inout PxaObjectStore) -> PixelArtJSON {
        var fields: [String: PixelArtJSON] = [
            "kind": .string(scope.kind.rawValue),
            "layers": .array(scope.layerIDs.map(\.uuidString).sorted().map { .string($0) }),
            "frames": .array(scope.frameIDs.map(\.uuidString).sorted().map { .string($0) })
        ]
        if let selection = scope.selection { fields["selection"] = PixelFocusCodec.encode(selection, into: &store) }
        return .object(fields)
    }

    private static func decodeScope(_ json: PixelArtJSON, store: PxaObjectStore, section: String) throws -> PixelScope {
        let fields = try PixelArtFields(json, section: "\(section).scope")
        let kindName = try fields.string("kind")
        guard let kind = PixelScope.Kind(rawValue: kindName) else {
            throw PixelArtError.invalid(section, "alcance desconocido «\(kindName)»")
        }
        let layers = try fields.uuids("layers")
        let frames = try fields.uuids("frames")
        guard layers.count <= PxaLimits.layers, frames.count <= PxaLimits.frames else {
            throw PixelArtError.limit(section, "el alcance menciona demasiadas capas o fotogramas")
        }
        var scope = PixelScope(kind: kind, layerIDs: Set(layers), frameIDs: Set(frames))
        if fields.has("selection") {
            scope.selection = try PixelFocusCodec.decode(try fields.raw("selection"), store: store, section: section)
        }
        guard (kind == .selection) == (scope.selection != nil) else {
            throw PixelArtError.invalid(section, "solo el alcance «selección» lleva máscara")
        }
        try fields.finish()
        return scope
    }

    // MARK: Propuesta

    static func encode(_ proposal: PixelProposal, into store: inout PxaObjectStore) -> PxaObjectRef {
        let changes = proposal.paletteChanges.map { change -> PixelArtJSON in
            var fields: [String: PixelArtJSON] = ["id": .int(Int(change.id))]
            if let before = change.before { fields["before"] = PixelArtStateCodec.entryJSON(before) }
            if let after = change.after { fields["after"] = PixelArtStateCodec.entryJSON(after) }
            return .object(fields)
        }
        var fields: [String: PixelArtJSON] = [
            "id": .string(proposal.id.uuidString), "documentID": .string(proposal.documentID.uuidString),
            "baseRevisionID": .string(proposal.baseRevisionID.uuidString), "baseStateHash": .string(proposal.baseStateHash),
            "scope": encode(proposal.scope, into: &store), "prompt": .string(proposal.prompt),
            "settings": .object(proposal.settings.mapValues { .string($0) }), "summary": .string(proposal.summary),
            "operations": .array(proposal.operationSummaries.map { .string($0) }),
            "reservedEntryIDs": .array(proposal.reservedEntryIDs.map { .int(Int($0)) }), "paletteChanges": .array(changes),
            "affected": PixelHistoryCodec.encode(proposal.affected),
            "resources": .object(["objects": .int(proposal.estimatedObjects), "bytes": .int(proposal.estimatedBytes)]),
            "status": .string(proposal.status.rawValue), "createdAt": .string(PxaDates.format(proposal.createdAt))
        ]
        if let state = proposal.proposedState { fields["state"] = state.json }
        if let model = proposal.model { fields["model"] = .string(model) }
        if let applied = proposal.appliedRevisionID { fields["appliedRevisionID"] = .string(applied.uuidString) }
        if let replaces = proposal.replaces { fields["replaces"] = .string(replaces.uuidString) }
        return store.put(.proposal, fields: fields)
    }

    static func decodeProposal(_ ref: PxaObjectRef, from store: PxaObjectStore) throws -> PixelProposal {
        let fields = try store.fields(ref)
        let section = fields.section
        let statusName = try fields.string("status")
        guard let status = PixelProposalStatus(rawValue: statusName), status != .preparing else {
            throw PixelArtError.invalid(section, "estado de propuesta no válido en un archivo «\(statusName)»")
        }
        let settingsMap = try fields.object("settings")
        let settings = try settingsMap.mapValues { value -> String in
            guard case .string(let text) = value else { throw PixelArtError.invalid(section, "los ajustes deben ser texto") }
            return text
        }
        guard settings.count <= 64 else { throw PixelArtError.limit(section, "demasiados ajustes") }
        var proposal = PixelProposal(id: try fields.uuid("id"), documentID: try fields.uuid("documentID"),
                                     baseRevisionID: try fields.uuid("baseRevisionID"),
                                     baseStateHash: try fields.string("baseStateHash"),
                                     scope: try decodeScope(try fields.raw("scope"), store: store, section: section),
                                     prompt: try fields.string("prompt"), settings: settings)
        guard PxaObjectRef.isValidHash(proposal.baseStateHash) else { throw PixelArtError.invalid(section, "hash base inválido") }
        try PixelArtText.validateMessage(proposal.prompt, section: section)
        proposal.summary = try fields.string("summary")
        try PixelArtText.validateMessage(proposal.summary, section: section)
        proposal.proposedState = try fields.optionalRef("state", as: .documentState)
        proposal.operationSummaries = try fields.array("operations").map { item in
            guard case .string(let text) = item else { throw PixelArtError.invalid(section, "las operaciones deben ser texto") }
            try PixelArtText.validateMessage(text, section: section)
            return text
        }
        proposal.reservedEntryIDs = try fields.array("reservedEntryIDs").map { item in
            guard case .int(let number) = item, (1...Int(PxaLimits.paletteEntryIDMax)).contains(number) else {
                throw PixelArtError.invalid(section, "ID reservado fuera de rango")
            }
            return UInt32(number)
        }
        proposal.paletteChanges = try decodeChanges(try fields.array("paletteChanges"), section: section)
        proposal.affected = try PixelHistoryCodec.decodeAffected(try fields.raw("affected"), section: section)
        let resources = try fields.nested("resources")
        proposal.estimatedObjects = try resources.int("objects", in: 0...PxaLimits.objects)
        proposal.estimatedBytes = try resources.int("bytes", in: 0...PxaLimits.uncompressedBytes)
        try resources.finish()
        proposal.status = status
        proposal.model = try fields.optionalString("model")
        proposal.createdAt = try PxaDates.parse(try fields.string("createdAt"), section: section)
        proposal.appliedRevisionID = try fields.optionalUUID("appliedRevisionID")
        proposal.replaces = try fields.optionalUUID("replaces")
        try fields.finish()
        guard status != .ready || proposal.proposedState != nil else {
            throw PixelArtError.invalid(section, "una propuesta lista necesita su estado propuesto")
        }
        proposal.needsRevalidation = status == .ready
        return proposal
    }

    private static func decodeChanges(_ items: [PixelArtJSON], section: String) throws -> [PixelPaletteChange] {
        guard items.count <= PxaLimits.paletteEntries * 2 else { throw PixelArtError.limit(section, "demasiados cambios de paleta") }
        return try items.map { item in
            let change = try PixelArtFields(item, section: "\(section).paletteChanges")
            let id = try change.int("id", in: 1...Int(PxaLimits.paletteEntryIDMax))
            let before = try change.has("before") ? PixelArtStateCodec.decodeEntry(try change.raw("before"), section: section) : nil
            let after = try change.has("after") ? PixelArtStateCodec.decodeEntry(try change.raw("after"), section: section) : nil
            try change.finish()
            return PixelPaletteChange(id: UInt32(id), before: before, after: after)
        }
    }

    // MARK: Conversación

    static func encode(_ assistant: PixelAssistantState, into store: inout PxaObjectStore) -> PxaObjectRef {
        let prepared = assistant.preparedForSave()
        let messages = prepared.messages.map { message -> PixelArtJSON in
            var fields: [String: PixelArtJSON] = [
                "id": .string(message.id.uuidString), "role": .string(message.role.rawValue),
                "date": .string(PxaDates.format(message.date)), "text": .string(message.text)
            ]
            if let proposal = message.proposalID { fields["proposalID"] = .string(proposal.uuidString) }
            return .object(fields)
        }
        let proposals = prepared.proposals.map { encode($0, into: &store).json }
        return store.put(.assistantState, fields: ["messages": .array(messages), "draft": .string(prepared.draft),
                                                   "proposals": .array(proposals)])
    }

    static func decode(_ ref: PxaObjectRef, from store: PxaObjectStore) throws -> PixelAssistantState {
        let fields = try store.fields(ref)
        let section = fields.section
        let messageItems = try fields.array("messages")
        guard messageItems.count <= 100_000 else { throw PixelArtError.limit(section, "demasiados mensajes") }
        let messages = try messageItems.map { item -> PixelAssistantMessage in
            let message = try PixelArtFields(item, section: "\(section).messages")
            let roleName = try message.string("role")
            guard let role = PixelMessageRole(rawValue: roleName) else { throw PixelArtError.invalid(section,
                                                                                                     "rol desconocido «\(roleName)»") }
            let parsed = PixelAssistantMessage(id: try message.uuid("id"), role: role,
                                               date: try PxaDates.parse(try message.string("date"), section: section),
                                               text: try message.string("text"), proposalID: try message.optionalUUID("proposalID"))
            try PixelArtText.validateMessage(parsed.text, section: section)
            try message.finish()
            return parsed
        }
        let draft = try fields.string("draft")
        try PixelArtText.validateMessage(draft, section: section)
        let proposalRefs = try fields.refs("proposals", as: .proposal)
        guard proposalRefs.count <= 4_096 else { throw PixelArtError.limit(section, "demasiadas propuestas") }
        let proposals = try proposalRefs.map { try decodeProposal($0, from: store) }
        try fields.finish()
        guard Set(messages.map(\.id)).count == messages.count, Set(proposals.map(\.id)).count == proposals.count else {
            throw PixelArtError.invalid(section, "hay IDs repetidos")
        }
        let known = Set(proposals.map(\.id))
        for message in messages {
            if let proposalID = message.proposalID, known.contains(proposalID) == false {
                throw PixelArtError.invalid(section, "un mensaje apunta a una propuesta inexistente")
            }
        }
        let state = PixelAssistantState(messages: messages, draft: draft, proposals: proposals)
        guard state.textBytes <= PxaLimits.assistantTextBytes else {
            throw PixelArtError.limit(section, "el texto del asistente supera \(PxaLimits.assistantTextBytes) bytes")
        }
        return state
    }

    // MARK: Registro de procedencia

    /// Valida el registro de una propuesta aceptada: prompt, ajustes, resumen, alcance y revisión base.
    static func validateRecord(_ ref: PxaObjectRef, from store: PxaObjectStore) throws {
        let fields = try store.fields(ref)
        _ = try fields.uuid("proposalID")
        try PixelArtText.validateMessage(try fields.string("prompt"), section: fields.section)
        try PixelArtText.validateMessage(try fields.string("summary"), section: fields.section)
        _ = try fields.object("settings")
        guard PixelScope.Kind(rawValue: try fields.string("scope")) != nil else {
            throw PixelArtError.invalid(fields.section, "alcance desconocido")
        }
        _ = try fields.uuid("baseRevisionID")
        _ = try fields.optionalString("model")
        try fields.finish()
    }
}
