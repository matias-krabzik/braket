@testable import Krabzik
import XCTest

/// Archivo `.pxa` completo: ida y vuelta, validación, cambios pendientes, copias, guardado y recuperación.
final class PixelArtFileTests: XCTestCase {
    private let red = PixelRGBA(255, 0, 0)
    private let blue = PixelRGBA(0, 0, 255)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pxa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Documento con paleta, píxeles libres y vinculados, ramas de historia, conversación y una propuesta lista.
    private func richDocument() throws -> PixelArtDocument {
        var document = try PixelArtDocument(width: 40, height: 40)
        let ids = try document.core.reserveEntryIDs(2)
        let layer = document.state.layers[0].id
        let frame = document.state.frames[0].id
        func edit(_ document: inout PixelArtDocument, _ label: String, _ operations: [PixelOperation]) throws {
            try document.core.apply(PixelTransaction(label: label, operationKind: "test", scope: .document(document.state),
                                                     operations: operations))
        }
        try edit(&document, "Paleta", [.addPaletteEntry(PaletteEntry(id: ids[0], name: "piel", color: red)),
                                       .addPaletteEntry(PaletteEntry(id: ids[1], name: "sombra", color: blue))])
        try edit(&document, "Trazo", [.writePixels(layer: layer, frame: frame, writes: [PixelWrite(x: 0, y: 0, value: .linked(ids[0])),
                                                                                        PixelWrite(x: 1, y: 0, value: .free(red)),
                                                                                        PixelWrite(x: 39, y: 39, value: .linked(ids[1]))])])
        try edit(&document, "Otro trazo", [.writePixels(layer: layer, frame: frame, writes: [PixelWrite(x: 2, y: 2, value: .free(blue))])])
        _ = try document.core.undo()
        try edit(&document, "Rama", [.writePixels(layer: layer, frame: frame, writes: [PixelWrite(x: 3, y: 3, value: .free(blue))])])
        _ = try document.core.undo()
        document.editor.zoomPercent = 1_200
        document.editor.drawColor = .linked(ids[0])
        document.editor.selection = .rectangle(x: 2, y: 2, width: 5, height: 5, canvasWidth: 40, canvasHeight: 40)
        document.exportPresets = [PixelExportPreset(name: "Hoja", format: "spriteSheet", scale: 4, layerIDs: [layer], frameIDs: [frame],
                                                    margin: 2, spacing: 1, outputName: "hoja.png")]
        try document.assistant.addMessage(PixelAssistantMessage(role: .user, text: "Dale una paleta nocturna"))
        let started = try document.assistant.begin(prompt: "Paleta nocturna", scope: .document(document.state), core: document.core)
        let night = try document.core.materialize([.replacePaletteColors([ids[0]: blue])], scope: .document(document.state))
        var core = document.core
        var assistant = document.assistant
        try assistant.complete(requestID: try XCTUnwrap(started.requestID), proposed: night, summary: "Tonos fríos", model: "m",
                               core: &core)
        try assistant.setDraft("seguir luego")
        document.core = core
        document.assistant = assistant
        return document
    }

    private func rewrite(_ data: Data, _ edit: (inout [PxaZip.Entry]) throws -> Void) throws -> Data {
        var entries = try PxaZip.read(data)
        try edit(&entries)
        return try PxaZip.write(entries)
    }

    private func manifest(of data: Data) throws -> PxaManifest {
        let entry = try XCTUnwrap(try PxaZip.read(data).first { $0.name == PxaZip.manifestName })
        return try PxaManifest.parse(entry.data)
    }

    private func replaceManifest(_ data: Data, _ edit: (inout PxaManifest) -> Void) throws -> Data {
        try rewrite(data) { entries in
            let index = try XCTUnwrap(entries.firstIndex { $0.name == PxaZip.manifestName })
            var parsed = try PxaManifest.parse(entries[index].data)
            edit(&parsed)
            entries[index].data = parsed.data()
        }
    }

    private func assertThrows(_ data: Data, kind: PixelArtError.Kind? = nil, _ message: String, file: StaticString = #filePath,
                              line: UInt = #line) {
        XCTAssertThrowsError(try PixelArtFile.read(data), message, file: file, line: line) { error in
            guard let kind else { return }
            XCTAssertEqual((error as? PixelArtError)?.kind, kind, "\(message): \(error)", file: file, line: line)
        }
    }

    // MARK: Ida y vuelta

    func testRichDocumentRoundTripsEveryPart() throws {
        let document = try richDocument()
        let snapshot = try PixelArtFile.snapshot(of: document, writerVersion: "0.5.15")
        let loaded = try PixelArtFile.read(snapshot.data)
        XCTAssertEqual(loaded.documentID, document.documentID)
        XCTAssertEqual(loaded.state, document.state)
        XCTAssertEqual(loaded.core.history, document.core.history)
        XCTAssertEqual(loaded.core.history.cursorID, document.core.history.cursorID)
        XCTAssertTrue(loaded.core.history.canRedo, "Rehacer sigue disponible tras reabrir")
        XCTAssertEqual(loaded.core.history.otherBranches.count, 2, "«Otro trazo» y «Rama» siguen accesibles")
        XCTAssertEqual(loaded.editor, document.editor)
        XCTAssertEqual(loaded.exportPresets, document.exportPresets)
        XCTAssertEqual(loaded.assistant.messages, document.assistant.messages)
        XCTAssertEqual(loaded.assistant.draft, "seguir luego")
        XCTAssertEqual(loaded.assistant.proposals.first?.status, .ready)
        XCTAssertEqual(loaded.assistant.proposals.first?.needsRevalidation, false, "se revalidó al abrir")
        XCTAssertEqual(loaded.core.nextPaletteEntryID, document.core.nextPaletteEntryID)
        XCTAssertEqual(loaded.core.everUsedEntryIDs, document.core.everUsedEntryIDs)
        XCTAssertEqual(snapshot.manifest.writerVersion, "0.5.15")
        XCTAssertEqual(try PixelArtFile.snapshot(of: loaded, savedAt: snapshot.manifest.savedAt, writerVersion: "0.5.15",
                                                 saveID: snapshot.manifest.saveID).data.count,
                       snapshot.data.count, "guardar lo recién abierto da el mismo contenido")
    }

    func testTheSameFileOpensIdenticallyAtAnotherLocationWithoutItsSources() throws {
        let snapshot = try PixelArtFile.snapshot(of: try richDocument())
        let first = directory.appendingPathComponent("a.pxa")
        try snapshot.data.write(to: first)
        let elsewhere = directory.appendingPathComponent("otra carpeta", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let second = elsewhere.appendingPathComponent("copia.pxa")
        try FileManager.default.copyItem(at: first, to: second)
        let one = try PixelArtFileStore.open(first).document
        let two = try PixelArtFileStore.open(second).document
        XCTAssertEqual(one.state, two.state)
        XCTAssertEqual(one.core.history, two.core.history)
        XCTAssertEqual(one.documentID, two.documentID)
    }

    func testSnapshotsAreDeterministicAndContainOnlyReachableObjects() throws {
        let document = try richDocument()
        let first = try PixelArtFile.snapshot(of: document, savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                              saveID: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID())
        let second = try PixelArtFile.snapshot(of: document, savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                               saveID: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID())
        XCTAssertEqual(first.data, second.data)
        var orphan = document
        _ = try orphan.core.storeProposedState(try orphan.core.materialize([.setFrameDuration(orphan.state.frames[0].id, milliseconds: 7)],
                                                                           scope: .document(orphan.state)))
        let withOrphan = try PixelArtFile.snapshot(of: orphan, savedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                   saveID: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID())
        XCTAssertEqual(withOrphan.manifest.objectCount, first.manifest.objectCount, "lo que nada referencia no se guarda")
    }

    func testThumbnailIsGeneratedAndAnInvalidOneIsDiscardedWithAWarning() throws {
        let snapshot = try PixelArtFile.snapshot(of: try richDocument())
        let preview = try XCTUnwrap(try PxaZip.read(snapshot.data).first { $0.name == PxaZip.previewName })
        XCTAssertTrue(PixelArtPreview.isAcceptable(preview.data))
        XCTAssertTrue(try PixelArtFile.read(snapshot.data).warnings.isEmpty)
        let broken = try rewrite(snapshot.data) { entries in
            let index = try XCTUnwrap(entries.firstIndex { $0.name == PxaZip.previewName })
            entries[index].data = Data("no es un png".utf8)
        }
        XCTAssertEqual(try PixelArtFile.read(broken).warnings.count, 1)
        XCTAssertFalse(PixelArtPreview.isAcceptable(Data(count: 10)))
    }

    // MARK: Validación

    func testReadRejectsEveryKindOfDamage() throws {
        let data = try PixelArtFile.snapshot(of: try richDocument()).data
        let parsed = try manifest(of: data)

        assertThrows(try rewrite(data) { entries in
            let index = try XCTUnwrap(entries.firstIndex { $0.name.hasPrefix(PxaZip.objectPrefix) && $0.data.count == PxaTile.byteCount })
            entries[index].data = Data(count: PxaTile.byteCount)
        }, kind: .integrity, "contenido distinto al de su hash")

        assertThrows(try rewrite(data) { entries in
            entries.removeAll { $0.name == PxaZip.objectName(parsed.history.hash) }
        }, "falta un objeto referenciado")

        let extra = Data("sobrante".utf8)
        assertThrows(try rewrite(data) { entries in
            entries.append(PxaZip.Entry(name: PxaZip.objectName(PxaObjectStore.hash(of: extra)), data: extra))
        }, "totales que no coinciden con el manifiesto")

        assertThrows(try replaceManifest(try rewrite(data) { entries in
            entries.append(PxaZip.Entry(name: PxaZip.objectName(PxaObjectStore.hash(of: extra)), data: extra))
        }) { $0.objectCount += 1
        $0.uncompressedBytes += extra.count }, kind: .invalid, "objeto huérfano")

        assertThrows(try replaceManifest(data) { $0.nextPaletteEntryID = 1 }, kind: .invalid, "contador menor que un ID usado")
        assertThrows(try replaceManifest(data) { $0.objectCount += 1 }, kind: .integrity, "total de objetos mentido")
        assertThrows(try rewrite(data) { entries in entries.removeAll { $0.name == PxaZip.manifestName } }, "sin manifiesto")
        assertThrows(try replaceManifest(data) { $0.currentState = $0.editorState }, "tipo equivocado en una referencia")
    }

    func testTheCurrentStateMustBeTheStateOfTheCursor() throws {
        let document = try richDocument()
        let data = try PixelArtFile.snapshot(of: document).data
        let parsed = try manifest(of: data)
        let other = try XCTUnwrap(document.core.history.revisions.values.first { $0.afterState != parsed.currentState }?.afterState)
        assertThrows(try replaceManifest(data) { $0.currentState = other }, kind: .invalid, "estado actual distinto al del cursor")
    }

    func testHistoryRevisionsThatLieAboutWhatTheyAffectAreRejected() throws {
        var document = try richDocument()
        let bogus = UUID()
        let revision = document.core.history.pathToCursor.last ?? document.core.history.cursor
        var store = document.core.store
        var forged = revision
        forged.affected.layers = [bogus]
        let forgedRef = PixelHistoryCodec.encode(forged, into: &store)
        var history = document.core.history
        var replaced = history.revisions.values.map { $0.id == revision.id ? forged : $0 }
        replaced.sort { $0.id.uuidString < $1.id.uuidString }
        history = try PixelHistory(revisions: replaced, rootID: history.rootID, cursorID: history.cursorID,
                                   preferredChild: history.preferredChild, bookmarks: history.bookmarks)
        _ = forgedRef
        document.core = try PixelDocumentCore(documentID: document.documentID, store: store, history: history,
                                              nextPaletteEntryID: document.core.nextPaletteEntryID,
                                              everUsedEntryIDs: document.core.everUsedEntryIDs)
        XCTAssertThrowsError(try PixelArtFile.snapshot(of: document), "el guardado también valida lo que escribe")
    }

    func testAFutureMinorVersionOpensReadOnlyAndNeverSaves() throws {
        let data = try PixelArtFile.snapshot(of: try richDocument()).data
        let future = try replaceManifest(data) { $0.formatMinor = 4 }
        let document = try PixelArtFile.read(future)
        XCTAssertTrue(document.isReadOnly)
        XCTAssertThrowsError(try PixelArtFile.snapshot(of: document)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .unsupported)
        }
        let major = try rewrite(data) { entries in
            let index = try XCTUnwrap(entries.firstIndex { $0.name == PxaZip.manifestName })
            var text = String(decoding: entries[index].data, as: UTF8.self)
            text = text.replacingOccurrences(of: "\"major\":1", with: "\"major\":2")
            entries[index].data = Data(text.utf8)
        }
        assertThrows(major, kind: .unsupported, "versión mayor desconocida")
    }

    // MARK: Recuperación parcial

    func testOnlyAHistoryFailureOffersARecoveredCopyWithTheCurrentState() throws {
        let document = try richDocument()
        let data = try PixelArtFile.snapshot(of: document).data
        let parsed = try manifest(of: data)
        let damaged = try rewrite(data) { entries in entries.removeAll { $0.name == PxaZip.objectName(parsed.history.hash) } }
        assertThrows(damaged, "el archivo no abre con su historial dañado")
        let recovered = try PixelArtFile.recoveredCopy(from: damaged)
        XCTAssertEqual(recovered.state, document.state, "el estado actual se verificó por completo")
        XCTAssertNotEqual(recovered.documentID, document.documentID)
        XCTAssertEqual(recovered.copiedFrom, document.documentID)
        XCTAssertTrue(recovered.partialHistory)
        XCTAssertEqual(recovered.core.history.count, 1, "no se presenta como poseedora de la historia completa")
        XCTAssertFalse(recovered.warnings.isEmpty)

        let brokenState = try rewrite(data) { entries in entries.removeAll { $0.name == PxaZip.objectName(parsed.currentState.hash) } }
        XCTAssertThrowsError(try PixelArtFile.recoveredCopy(from: brokenState), "si el estado actual no se demuestra, se rechaza")
    }

    // MARK: Cambios pendientes

    func testPendingChangesFollowTheContractOfPXA02() throws {
        var document = try PixelArtDocument(width: 16, height: 16)
        XCTAssertTrue(document.needsClosePrompt, "un documento nuevo nunca se guardó")
        let snapshot = try PixelArtFile.snapshot(of: document)
        document.markSaved(snapshot.mark)
        XCTAssertFalse(document.hasAnyUnsavedChange)

        document.editor.zoomPercent = 3_200
        document.editor.selection = PixelSelection()
        XCTAssertTrue(document.hasUnsavedAuxiliaryChanges)
        XCTAssertFalse(document.needsClosePrompt, "un cambio de zoom aislado no provoca el diálogo de cierre")

        let layer = document.state.layers[0].id
        let frame = document.state.frames[0].id
        try document.core.apply(PixelTransaction(label: "p", operationKind: "t", scope: .document(document.state),
                                                 operations: [.writePixels(layer: layer, frame: frame,
                                                                           writes: [PixelWrite(x: 1, y: 1, value: .free(red))])]))
        XCTAssertTrue(document.hasUnsavedArtisticChanges)
        XCTAssertTrue(document.needsClosePrompt)
        _ = try document.core.undo()
        XCTAssertTrue(document.hasUnsavedArtisticChanges, "ahora hay una continuación nueva para Rehacer")
        _ = try document.core.redo()
        _ = try document.core.undo()
    }

    func testUndoAndRedoBackToTheSavedPointLeavesTheDocumentClean() throws {
        var document = try PixelArtDocument(width: 16, height: 16)
        let layer = document.state.layers[0].id
        let frame = document.state.frames[0].id
        try document.core.apply(PixelTransaction(label: "p", operationKind: "t", scope: .document(document.state),
                                                 operations: [.writePixels(layer: layer, frame: frame,
                                                                           writes: [PixelWrite(x: 1, y: 1, value: .free(red))])]))
        document.markSaved(try PixelArtFile.snapshot(of: document).mark)
        _ = try document.core.undo()
        XCTAssertTrue(document.hasUnsavedArtisticChanges, "el cursor cambió: es historia persistente")
        _ = try document.core.redo()
        XCTAssertFalse(document.hasUnsavedArtisticChanges, "mismo cursor, mismo grafo, mismos datos")
    }

    func testEditsDuringASaveStayPendingAndOnlyTheCapturedGenerationIsMarked() throws {
        var document = try PixelArtDocument(width: 16, height: 16)
        let snapshot = try PixelArtFile.snapshot(of: document)
        let layer = document.state.layers[0].id
        let frame = document.state.frames[0].id
        try document.core.apply(PixelTransaction(label: "durante el guardado", operationKind: "t", scope: .document(document.state),
                                                 operations: [.writePixels(layer: layer, frame: frame,
                                                                           writes: [PixelWrite(x: 2, y: 2, value: .free(red))])]))
        document.markSaved(snapshot.mark)
        XCTAssertTrue(document.hasUnsavedArtisticChanges, "lo editado durante el guardado sigue pendiente")
        XCTAssertEqual(try PixelArtFile.read(snapshot.data).state.pixel(layer: layer, frame: frame, x: 2, y: 2), .empty)
    }

    func testNewMessagesAndProposalsCountForTheClosePromptButTheDraftDoesNot() throws {
        var document = try richDocument()
        document.markSaved(try PixelArtFile.snapshot(of: document).mark)
        XCTAssertFalse(document.hasAnyUnsavedChange)
        try document.assistant.setDraft("otro borrador")
        XCTAssertTrue(document.hasUnsavedAuxiliaryChanges)
        XCTAssertFalse(document.needsClosePrompt)
        try document.assistant.addMessage(PixelAssistantMessage(role: .assistant, text: "respuesta nueva"))
        XCTAssertTrue(document.hasUnsavedAssistantContent)
        XCTAssertTrue(document.needsClosePrompt)
    }

    // MARK: Copias

    func testACopyKeepsHistoryUnderANewIDAndRecordsItsOrigin() throws {
        let document = try richDocument()
        let copy = try document.makeCopy()
        XCTAssertNotEqual(copy.documentID, document.documentID)
        XCTAssertEqual(copy.copiedFrom, document.documentID)
        XCTAssertEqual(copy.core.history, document.core.history)
        XCTAssertEqual(copy.assistant.proposals.first?.status, .ready, "la propuesta se revalidó y adoptó el nuevo ID")
        XCTAssertEqual(copy.assistant.proposals.first?.documentID, copy.documentID)
        let reopened = try PixelArtFile.read(try PixelArtFile.snapshot(of: copy).data)
        XCTAssertEqual(reopened.copiedFrom, document.documentID)
        XCTAssertTrue(copy.hasUnsavedArtisticChanges, "una copia no hereda el punto de guardado")
    }

    func testAReducedCopyOmitsBranchesAndUnappliedProposalsWithoutBrokenReferences() throws {
        let document = try richDocument()
        let reduced = try document.makeReducedCopy(keepingAncestors: 0)
        XCTAssertTrue(reduced.partialHistory)
        XCTAssertEqual(reduced.core.history.count, 1)
        XCTAssertTrue(reduced.assistant.proposals.isEmpty, "las propuestas no aplicadas se omiten")
        XCTAssertEqual(reduced.assistant.messages, document.assistant.messages, "los mensajes quedan como texto")
        XCTAssertEqual(reduced.state, document.state)
        let reopened = try PixelArtFile.read(try PixelArtFile.snapshot(of: reduced).data)
        XCTAssertEqual(reopened.state, document.state)
        XCTAssertTrue(reopened.partialHistory)
        XCTAssertEqual(document.core.history.count, 5, "el original queda intacto")
    }

    // MARK: Guardado en disco

    func testSavingCreatesTheFileAndSavingAgainNeedsTheCurrentFingerprint() throws {
        let document = try richDocument()
        let url = directory.appendingPathComponent("dibujo.pxa")
        let first = try PixelArtFile.snapshot(of: document)
        let fingerprint = try PixelArtFileStore.save(first, to: url, expecting: nil)
        XCTAssertEqual(try PixelArtFileStore.fingerprint(of: url), fingerprint)
        let opened = try PixelArtFileStore.open(url)
        XCTAssertEqual(opened.document.state, document.state)
        XCTAssertEqual(opened.fingerprint, fingerprint)
        let second = try PixelArtFile.snapshot(of: opened.document)
        XCTAssertNoThrow(try PixelArtFileStore.save(second, to: url, expecting: fingerprint))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "no quedan temporales")
    }

    func testAnExternalChangeIsNeverOverwrittenSilently() throws {
        let document = try richDocument()
        let url = directory.appendingPathComponent("dibujo.pxa")
        let fingerprint = try PixelArtFileStore.save(try PixelArtFile.snapshot(of: document), to: url, expecting: nil)
        let external = Data("otro programa escribió aquí".utf8)
        try external.write(to: url)
        XCTAssertThrowsError(try PixelArtFileStore.save(try PixelArtFile.snapshot(of: document), to: url,
                                                        expecting: fingerprint)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .conflict)
        }
        XCTAssertEqual(try Data(contentsOf: url), external, "el archivo ajeno sigue intacto")
        XCTAssertThrowsError(try PixelArtFileStore.save(try PixelArtFile.snapshot(of: document), to: url, expecting: nil), "ya existía")
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    func testAFailureInAnySavePhaseKeepsTheLastValidVersion() throws {
        let document = try richDocument()
        let url = directory.appendingPathComponent("dibujo.pxa")
        let original = try PixelArtFile.snapshot(of: document)
        let fingerprint = try PixelArtFileStore.save(original, to: url, expecting: nil)
        var edited = document
        try edited.core.apply(PixelTransaction(label: "nueva", operationKind: "t", scope: .document(edited.state),
                                               operations: [.setFrameDuration(edited.state.frames[0].id, milliseconds: 321)]))
        let next = try PixelArtFile.snapshot(of: edited)
        struct Injected: Error {}
        for phase in PixelArtSavePhase.allCases {
            XCTAssertThrowsError(try PixelArtFileStore.save(next, to: url, expecting: fingerprint, hook: { current in
                if current == phase { throw Injected() }
            }), "\(phase)")
            XCTAssertEqual(try Data(contentsOf: url), original.data, "tras fallar en \(phase) queda la última versión válida")
            XCTAssertEqual(try PixelArtFileStore.open(url).document.state, document.state)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
            XCTAssertTrue(leftovers.isEmpty, "sin temporales tras fallar en \(phase)")
        }
        XCTAssertNoThrow(try PixelArtFileStore.save(next, to: url, expecting: fingerprint))
    }

    func testSavingRejectsMissingFoldersAndNonRegularTargets() throws {
        let snapshot = try PixelArtFile.snapshot(of: try PixelArtDocument(width: 8, height: 8))
        XCTAssertThrowsError(try PixelArtFileStore.save(snapshot, to: directory.appendingPathComponent("no/existe/a.pxa"), expecting: nil))
        let folder = directory.appendingPathComponent("carpeta.pxa", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try PixelArtFileStore.save(snapshot, to: folder, expecting: nil))
        XCTAssertThrowsError(try PixelArtFileStore.open(folder))
        let real = directory.appendingPathComponent("real.pxa")
        try PixelArtFileStore.save(snapshot, to: real, expecting: nil)
        let link = directory.appendingPathComponent("enlace.pxa")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try PixelArtFileStore.open(link), "un enlace simbólico no es un archivo regular")
        XCTAssertThrowsError(try PixelArtFileStore.open(directory.appendingPathComponent("falta.pxa")))
    }

    // MARK: Recuperación local

    func testAutosavePolicyWaitsForQuietOrForTheMaximumInterval() {
        let policy = PixelAutosavePolicy()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(policy.shouldCapture(now: start, lastChange: nil, firstChange: nil, isWriting: false), "nada pendiente")
        XCTAssertFalse(policy.shouldCapture(now: start.addingTimeInterval(1), lastChange: start, firstChange: start, isWriting: false))
        XCTAssertTrue(policy.shouldCapture(now: start.addingTimeInterval(2), lastChange: start, firstChange: start, isWriting: false))
        XCTAssertFalse(policy
            .shouldCapture(now: start.addingTimeInterval(29), lastChange: start.addingTimeInterval(28.5), firstChange: start,
                           isWriting: false), "edición continua, todavía no 30 s")
        XCTAssertTrue(policy.shouldCapture(now: start.addingTimeInterval(30), lastChange: start.addingTimeInterval(29.5),
                                           firstChange: start,
                                           isWriting: false))
        XCTAssertFalse(policy.shouldCapture(now: start.addingTimeInterval(60), lastChange: start, firstChange: start, isWriting: true),
                       "no mientras otra escritura está en curso")
    }

    // La recuperación por trabajo (PXA-08) se prueba en PixelArtRecoveryTests.
}
