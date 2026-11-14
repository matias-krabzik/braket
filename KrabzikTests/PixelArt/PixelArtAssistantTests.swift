@testable import Krabzik
import XCTest

/// Propuestas de Codex y conversación persistente de PXA-04 §3–§6.
final class PixelArtAssistantTests: XCTestCase {
    private let red = PixelRGBA(255, 0, 0)
    private let blue = PixelRGBA(0, 0, 255)

    private func makeCore() throws -> PixelDocumentCore {
        var state = PixelArtState.blank(width: 40, height: 40)
        state.palette.entries = [PaletteEntry(id: 7, name: "piel", color: red), PaletteEntry(id: 9, name: "madera", color: red)]
        state.layers.append(PixelLayer(name: "Detalle"))
        var cel = PixelCel()
        cel.setPixel(x: 0, y: 0, to: .linked(7))
        cel.setPixel(x: 1, y: 0, to: .free(red))
        cel.setPixel(x: 35, y: 35, to: .linked(7))
        state.frames[0].cels[state.layers[0].id] = cel
        return try PixelDocumentCore(state: state)
    }

    private func nightPalette(_ core: PixelDocumentCore) throws -> PixelArtState {
        try core.materialize([.replacePaletteColors([7: blue])], scope: .document(core.state))
    }

    private func submit(_ assistant: inout PixelAssistantState, _ core: inout PixelDocumentCore, scope: PixelScope? = nil,
                        proposed: PixelArtState, reserve: Int = 0) throws -> UUID {
        let started = try assistant.begin(prompt: "Dale una paleta nocturna", scope: scope ?? .document(core.state), core: core)
        if reserve > 0 { _ = try assistant.reserveEntryIDs(for: started.id, count: reserve, core: &core) }
        let requestID = try XCTUnwrap(started.requestID)
        try assistant.complete(requestID: requestID, proposed: proposed, summary: "Tonos fríos", operationSummaries: ["Cambiar colores"],
                               model: "modelo-x", core: &core)
        return started.id
    }

    // MARK: Ciclo de vida

    func testAProposalIsIsolatedAndDoesNotChangeTheDocument() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let before = core.state
        let id = try submit(&assistant, &core, proposed: try nightPalette(core))
        let proposal = try XCTUnwrap(assistant.proposal(id))
        XCTAssertEqual(proposal.status, .ready)
        XCTAssertEqual(core.state, before, "la propuesta no cambia píxeles, vínculos, capas ni fotogramas")
        XCTAssertEqual(core.history.count, 1)
        XCTAssertEqual(proposal.paletteChanges.map(\.id), [7])
        XCTAssertEqual(proposal.paletteChanges.first?.before?.color, red)
        XCTAssertEqual(proposal.paletteChanges.first?.after?.color, blue)
        XCTAssertGreaterThan(proposal.estimatedObjects, 0)
        XCTAssertEqual(proposal.model, "modelo-x")
        XCTAssertEqual(assistant.pending?.id, id)
    }

    func testOnlyOneTaskAndOnePendingProposalPerDocument() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let first = try assistant.begin(prompt: "uno", scope: .document(core.state), core: core)
        XCTAssertThrowsError(try assistant.begin(prompt: "dos", scope: .document(core.state), core: core), "ya hay una ejecutándose")
        try assistant.complete(requestID: try XCTUnwrap(first.requestID), proposed: try nightPalette(core), summary: "ok", core: &core)
        XCTAssertThrowsError(try assistant.begin(prompt: "tres", scope: .document(core.state), core: core), "hay una lista")
        assistant.discard(first.id)
        XCTAssertEqual(assistant.proposal(first.id)?.status, .discarded)
        XCTAssertNoThrow(try assistant.begin(prompt: "cuatro", scope: .document(core.state), core: core))
    }

    func testAskingForAnAdjustmentKeepsTheBaseAndReplacesThePendingProposal() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let first = try submit(&assistant, &core, proposed: try nightPalette(core))
        let adjustment = try assistant.beginAdjustment(of: first, prompt: "más oscuro", core: core)
        XCTAssertEqual(adjustment.baseRevisionID, assistant.proposal(first)?.baseRevisionID)
        XCTAssertEqual(adjustment.scope, assistant.proposal(first)?.scope)
        let darker = try core.materialize([.replacePaletteColors([7: PixelRGBA(0, 0, 100)])], scope: .document(core.state))
        try assistant.complete(requestID: try XCTUnwrap(adjustment.requestID), proposed: darker, summary: "más oscuro", core: &core)
        XCTAssertEqual(assistant.proposal(first)?.status, .discarded, "la anterior queda reemplazada")
        XCTAssertEqual(assistant.pending?.id, adjustment.id)
    }

    // MARK: Rechazos locales

    func testProposalsThatBreakScopeLocksOrReferencesAreRejectedLocally() throws {
        var core = try makeCore()
        let layers = core.state.layers.map(\.id)
        let frame = core.state.frames[0].id
        var assistant = PixelAssistantState()
        let mask = PixelSelection.rectangle(x: 0, y: 0, width: 4, height: 4, canvasWidth: 40, canvasHeight: 40)
        let scope = PixelScope.selection(mask, layer: layers[0], frame: frame)

        // Fuera de alcance: toca un píxel fuera de la máscara.
        var outside = core.state
        outside.frames[0].cels[layers[0]]?.setPixel(x: 20, y: 20, to: .free(blue))
        var started = try assistant.begin(prompt: "p", scope: scope, core: core)
        XCTAssertThrowsError(try assistant.complete(requestID: try XCTUnwrap(started.requestID), proposed: outside, summary: "s",
                                                    core: &core)) {
            XCTAssertEqual(($0 as? PixelArtError)?.kind, .scope)
        }
        XCTAssertEqual(assistant.proposal(started.id)?.status, .failed)

        // Referencia inexistente: un píxel vinculado a un ID que no está en la paleta.
        var dangling = core.state
        dangling.frames[0].cels[layers[0]]?.setPixel(x: 2, y: 2, to: .linked(99))
        started = try assistant.begin(prompt: "p", scope: .document(core.state), core: core)
        XCTAssertThrowsError(try assistant.complete(requestID: try XCTUnwrap(started.requestID), proposed: dangling, summary: "s",
                                                    core: &core))

        // Capa bloqueada.
        try core.apply(PixelTransaction(label: "bloquear", operationKind: "test", scope: .document(core.state),
                                        operations: [.setLayerProperty(layers[0], .locked(true))]))
        var locked = core.state
        locked.frames[0].cels[layers[0]]?.setPixel(x: 3, y: 3, to: .free(blue))
        started = try assistant.begin(prompt: "p", scope: .document(core.state), core: core)
        XCTAssertThrowsError(try assistant.complete(requestID: try XCTUnwrap(started.requestID), proposed: locked, summary: "s",
                                                    core: &core)) {
            XCTAssertEqual(($0 as? PixelArtError)?.kind, .locked)
        }
        // Un cambio global de un ID que usa una capa bloqueada no se acepta omitiendo esa capa.
        started = try assistant.begin(prompt: "p", scope: .document(core.state), core: core)
        let global = try core.materialize([.replacePaletteColors([7: blue])], scope: .document(core.state))
        XCTAssertThrowsError(try assistant.complete(requestID: try XCTUnwrap(started.requestID), proposed: global, summary: "s",
                                                    core: &core)) {
            XCTAssertEqual(($0 as? PixelArtError)?.kind, .locked)
        }
        XCTAssertEqual(core.history.count, 2, "ninguna propuesta rechazada creó revisión")
    }

    func testAProposalThatChangesNothingOrUsesUnreservedIDsIsRejected() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        var started = try assistant.begin(prompt: "p", scope: .document(core.state), core: core)
        XCTAssertThrowsError(try assistant.complete(requestID: try XCTUnwrap(started.requestID), proposed: core.state, summary: "s",
                                                    core: &core))

        let fresh = try core.reserveEntryIDs(1)
        var withEntry = core.state
        withEntry.palette.entries.append(PaletteEntry(id: fresh[0], color: blue))
        started = try assistant.begin(prompt: "p", scope: .document(core.state), core: core)
        XCTAssertThrowsError(try assistant
            .complete(requestID: try XCTUnwrap(started.requestID), proposed: withEntry, summary: "s", core: &core),
                             "reservado para otro uso, no para esta propuesta")

        started = try assistant.begin(prompt: "p", scope: .document(core.state), core: core)
        let ids = try assistant.reserveEntryIDs(for: started.id, count: 1, core: &core)
        var withOwn = core.state
        withOwn.palette.entries.append(PaletteEntry(id: ids[0], color: blue))
        XCTAssertNoThrow(try assistant.complete(requestID: try XCTUnwrap(started.requestID), proposed: withOwn, summary: "s", core: &core))
    }

    func testLateAndCancelledResponsesCannotPublishAnything() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let started = try assistant.begin(prompt: "p", scope: .document(core.state), core: core)
        let requestID = try XCTUnwrap(started.requestID)
        assistant.cancel(started.id)
        XCTAssertEqual(assistant.proposal(started.id)?.status, .cancelled)
        XCTAssertThrowsError(try assistant.complete(requestID: requestID, proposed: try nightPalette(core), summary: "s", core: &core)) {
            XCTAssertEqual(($0 as? PixelArtError)?.kind, .stale)
        }
        XCTAssertNil(assistant.pending)

        let second = try assistant.begin(prompt: "q", scope: .document(core.state), core: core)
        try assistant.complete(requestID: try XCTUnwrap(second.requestID), proposed: try nightPalette(core), summary: "s", core: &core)
        XCTAssertThrowsError(try assistant
            .complete(requestID: try XCTUnwrap(second.requestID), proposed: try nightPalette(core), summary: "s", core: &core),
                             "un reintento duplicado no publica")
        XCTAssertThrowsError(try assistant.complete(requestID: UUID(), proposed: try nightPalette(core), summary: "s", core: &core))
    }

    func testEditingWhileThePromptRunsMakesTheResultStale() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let started = try assistant.begin(prompt: "p", scope: .document(core.state), core: core)
        let proposed = try nightPalette(core)
        try core.apply(PixelTransaction(label: "a mano", operationKind: "test", scope: .document(core.state),
                                        operations: [.writePixels(layer: core.state.layers[0].id, frame: core.state.frames[0].id,
                                                                  writes: [PixelWrite(x: 9, y: 9, value: .free(blue))])]))
        XCTAssertThrowsError(try assistant.complete(requestID: try XCTUnwrap(started.requestID), proposed: proposed, summary: "s",
                                                    core: &core)) {
            XCTAssertEqual(($0 as? PixelArtError)?.kind, .stale)
        }
        XCTAssertEqual(assistant.proposal(started.id)?.status, .stale)
    }

    // MARK: Aplicar

    func testApplyingCreatesOneRevisionWithProvenanceAndUndoesOffline() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let original = core.state
        let id = try submit(&assistant, &core, proposed: try nightPalette(core))
        guard case .applied(let revision) = try assistant.apply(id, to: &core) else { return XCTFail("debió aplicarse") }
        XCTAssertEqual(core.history.count, 2)
        XCTAssertEqual(revision.source, .codex)
        XCTAssertEqual(core.state.palette.entry(7)?.color, blue)
        XCTAssertEqual(core.state.frames[0].cels[core.state.layers[0].id]?.pixel(x: 1, y: 0), .free(red), "el libre no cambió")
        let record = try XCTUnwrap(revision.assistantRecord)
        XCTAssertNoThrow(try PixelAssistantCodec.validateRecord(record, from: core.store))
        XCTAssertEqual(assistant.proposal(id)?.status, .applied)

        XCTAssertNotNil(try core.undo())
        XCTAssertEqual(core.state, original, "deshacer no vuelve a consultar al modelo")
        XCTAssertNotNil(try core.redo())
        XCTAssertEqual(core.state.palette.entry(7)?.color, blue)
    }

    func testApplyingTwiceReturnsTheExistingRevisionAndNeverDuplicatesTheChange() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let id = try submit(&assistant, &core, proposed: try nightPalette(core))
        guard case .applied(let revision) = try assistant.apply(id, to: &core) else { return XCTFail("debió aplicarse") }
        let count = core.history.count
        XCTAssertEqual(try assistant.apply(id, to: &core), .alreadyApplied(revisionID: revision.id))
        XCTAssertEqual(core.history.count, count)
    }

    func testAManualEditMakesTheProposalStaleAndItCannotBeApplied() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let id = try submit(&assistant, &core, proposed: try nightPalette(core))
        try core.apply(PixelTransaction(label: "a mano", operationKind: "test", scope: .document(core.state),
                                        operations: [.writePixels(layer: core.state.layers[0].id, frame: core.state.frames[0].id,
                                                                  writes: [PixelWrite(x: 9, y: 9, value: .free(blue))])]))
        assistant.markStaleIfBaseChanged(core: core)
        XCTAssertEqual(assistant.proposal(id)?.status, .stale)
        XCTAssertThrowsError(try assistant.apply(id, to: &core)) { XCTAssertEqual(($0 as? PixelArtError)?.kind, .stale) }
        XCTAssertNotNil(assistant.proposal(id)?.proposedState, "se conserva para comparar")
    }

    func testReturningToTheSameVisualStateStillInvalidatesByGeneration() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let id = try submit(&assistant, &core, proposed: try nightPalette(core))
        _ = try core.apply(PixelTransaction(label: "a mano", operationKind: "test", scope: .document(core.state),
                                            operations: [.writePixels(layer: core.state.layers[0].id, frame: core.state.frames[0].id,
                                                                      writes: [PixelWrite(x: 9, y: 9, value: .free(blue))])]))
        _ = try core.undo()
        XCTAssertEqual(core.stateRef.hash, assistant.proposal(id)?.baseStateHash, "el mismo estado")
        assistant.markStaleIfBaseChanged(core: core)
        XCTAssertEqual(assistant.proposal(id)?.status, .stale, "pero otra generación: no se aplica por igualdad visual")
    }

    // MARK: Persistencia

    func testConversationAndProposalsRoundTripWithoutRunningAnything() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        try assistant.addMessage(PixelAssistantMessage(role: .user, text: "Dale una paleta nocturna"))
        let id = try submit(&assistant, &core, proposed: try nightPalette(core))
        try assistant.addMessage(PixelAssistantMessage(role: .assistant, text: "Listo", proposalID: id))
        try assistant.setDraft("borrador a medias")
        let running = try assistant.beginAdjustment(of: id, prompt: "más oscuro", core: core)

        var store = core.store
        let ref = PixelAssistantCodec.encode(assistant, into: &store)
        let loaded = try PixelAssistantCodec.decode(ref, from: store)
        XCTAssertEqual(loaded.messages, assistant.messages)
        XCTAssertEqual(loaded.draft, "borrador a medias")
        XCTAssertEqual(loaded.proposals.count, 2)
        XCTAssertEqual(loaded.proposal(running.id)?.status, .interrupted, "una tarea a medias se guarda como interrumpida")
        XCTAssertNil(loaded.proposal(running.id)?.requestID)
        XCTAssertNil(loaded.running, "al reabrir no se reanuda nada")
        let reopened = try XCTUnwrap(loaded.proposal(id))
        XCTAssertEqual(reopened.status, .ready)
        XCTAssertTrue(reopened.needsRevalidation, "pendiente de revalidación")
        XCTAssertEqual(reopened.paletteChanges, assistant.proposal(id)?.paletteChanges)
        XCTAssertEqual(reopened.scope, assistant.proposal(id)?.scope)
        XCTAssertEqual(PixelAssistantCodec.encode(loaded, into: &store), ref, "codificar es determinista")
    }

    func testReopenedProposalIsRevalidatedLocallyOrBecomesStale() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let id = try submit(&assistant, &core, proposed: try nightPalette(core))
        var store = core.store
        let ref = PixelAssistantCodec.encode(assistant, into: &store)

        var same = try PixelAssistantCodec.decode(ref, from: store)
        XCTAssertThrowsError(try same.apply(id, to: &core), "antes de revalidar no se aplica por inferencia")
        same.revalidate(core: core)
        XCTAssertEqual(same.proposal(id)?.status, .ready)
        XCTAssertEqual(same.proposal(id)?.needsRevalidation, false)
        XCTAssertNoThrow(try same.apply(id, to: &core))

        var changed = try PixelAssistantCodec.decode(ref, from: store)
        var other = try makeCore()
        try other.apply(PixelTransaction(label: "otra base", operationKind: "test", scope: .document(other.state),
                                         operations: [.setLayerProperty(other.state.layers[1].id, .name("distinta"))]))
        changed.revalidate(core: other)
        XCTAssertEqual(changed.proposal(id)?.status, .stale)
    }

    func testACopyWithAnotherDocumentIDNeedsExplicitAdoption() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        let id = try submit(&assistant, &core, proposed: try nightPalette(core))
        var store = core.store
        let ref = PixelAssistantCodec.encode(assistant, into: &store)
        let copy = try PixelDocumentCore(documentID: UUID(), store: core.store, history: core.history,
                                         nextPaletteEntryID: core.nextPaletteEntryID, everUsedEntryIDs: core.everUsedEntryIDs)

        var plain = try PixelAssistantCodec.decode(ref, from: store)
        plain.revalidate(core: copy)
        XCTAssertEqual(plain.proposal(id)?.status, .stale, "otro documento-ID sin adopción explícita")
        var adopted = try PixelAssistantCodec.decode(ref, from: store)
        adopted.revalidate(core: copy, adoptDocumentID: true)
        XCTAssertEqual(adopted.proposal(id)?.status, .ready)
        XCTAssertEqual(adopted.proposal(id)?.documentID, copy.documentID)
    }

    func testAReopenedProposalWhoseStateObjectIsMissingBecomesStale() throws {
        var core = try makeCore()
        var assistant = PixelAssistantState()
        _ = try submit(&assistant, &core, proposed: try nightPalette(core))
        var store = core.store
        let ref = PixelAssistantCodec.encode(assistant, into: &store)
        var broken = store.objects
        let proposalRef = try XCTUnwrap(try store.children(of: ref).first)
        let stateRef = try XCTUnwrap(try store.fields(proposalRef).optionalRef("state", as: .documentState))
        broken[stateRef.hash] = nil
        let brokenStore = PxaObjectStore(objects: broken)
        let brokenCore = try PixelDocumentCore(documentID: core.documentID, store: brokenStore, history: core.history,
                                               nextPaletteEntryID: core.nextPaletteEntryID, everUsedEntryIDs: core.everUsedEntryIDs)
        var copy = try PixelAssistantCodec.decode(ref, from: brokenStore)
        copy.revalidate(core: brokenCore)
        XCTAssertEqual(copy.proposals.first?.status, .stale, "sin el estado propuesto no se puede revalidar")
    }

    // MARK: Texto

    func testTheTextBudgetStopsAddingWithoutTruncatingWhatIsSaved() throws {
        var assistant = PixelAssistantState()
        let chunk = String(repeating: "a", count: PxaLimits.messageBytes)
        for _ in 0..<(PxaLimits.assistantTextBytes / PxaLimits.messageBytes) { try assistant.addMessage(PixelAssistantMessage(role: .user,
                                                                                                                              text: chunk))
                                                                                                                              }
        let saved = assistant.messages
        XCTAssertThrowsError(try assistant.addMessage(PixelAssistantMessage(role: .user, text: "una más"))) {
            XCTAssertEqual(($0 as? PixelArtError)?.kind, .capacity)
        }
        XCTAssertEqual(assistant.messages, saved, "no se truncó nada")
        XCTAssertThrowsError(try assistant.addMessage(PixelAssistantMessage(role: .user,
                                                                            text: String(repeating: "a",
                                                                                         count: PxaLimits.messageBytes + 1))))
        var other = PixelAssistantState()
        XCTAssertThrowsError(try other.addMessage(PixelAssistantMessage(role: .user, text: "a\u{1}b")))
        XCTAssertThrowsError(try other.setDraft("x\u{0}"))
    }
}
