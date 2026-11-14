@testable import Krabzik
import XCTest

/// Historial persistente de PXA-02: árbol, cursor, ramas, presupuesto y copia reducida.
final class PixelArtHistoryTests: XCTestCase {
    private var store = PxaObjectStore()

    /// Un estado distinto por cada letra, para que cada revisión tenga una referencia propia.
    private func state(_ marker: UInt8) -> PxaObjectRef {
        var value = PixelArtState.blank(width: 8, height: 8)
        value.frames[0].cels[value.layers[0].id] = {
            var cel = PixelCel()
            cel.setPixel(x: 0, y: 0, to: .free(PixelRGBA(marker, 0, 0)))
            return cel
        }()
        return PixelArtStateCodec.encode(value, into: &store)
    }

    private func revision(_ label: String, state: PxaObjectRef, offset: TimeInterval = 0) -> PixelRevision {
        PixelRevision(afterState: state, operationKind: "test", label: label,
                      createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offset))
    }

    /// raíz → A → B → C
    private func linearHistory() throws -> (PixelHistory, [String: UUID]) {
        var history = PixelHistory(initialState: state(0))
        var ids: [String: UUID] = ["raíz": history.rootID]
        for (index, name) in ["A", "B", "C"].enumerated() {
            let node = try history.commit(revision(name, state: state(UInt8(index + 1)), offset: Double(index)))
            ids[name] = node.id
        }
        return (history, ids)
    }

    // MARK: Deshacer, rehacer y ramas

    func testUndoRedoMoveTheCursorAndKeepStates() throws {
        var (history, ids) = try linearHistory()
        XCTAssertEqual(history.cursorID, ids["C"])
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
        let undone = try XCTUnwrap(history.undo())
        XCTAssertEqual(undone.label, "C")
        XCTAssertEqual(history.cursorID, ids["B"])
        XCTAssertEqual(history.currentState, undone.beforeState, "deshacer restaura el estado previo exacto")
        XCTAssertEqual(history.redo()?.id, ids["C"])
        XCTAssertNil(history.redo())
        for _ in 0..<3 { _ = history.undo() }
        XCTAssertNil(history.undo(), "la raíz no se deshace")
        XCTAssertFalse(history.canUndo)
    }

    /// Ejemplo normativo de PXA-02 §5: raíz → A → B → C, deshacer dos veces, pintar D.
    func testBranchExampleKeepsBothContinuations() throws {
        var (history, ids) = try linearHistory()
        _ = history.undo()
        _ = history.undo()
        XCTAssertEqual(history.cursorID, ids["A"])
        let d = try history.commit(revision("D", state: state(9), offset: 10))
        XCTAssertEqual(Set(history.children(of: ids["A"] ?? UUID()).map(\.label)), ["B", "D"])
        XCTAssertEqual(history.otherBranches.map(\.label), ["B"], "B → C sigue accesible")

        _ = history.undo()
        XCTAssertEqual(history.redo()?.id, d.id, "Rehacer elige la última continuación, D")
        _ = history.undo()
        try history.navigate(to: ids["B"] ?? UUID())
        XCTAssertEqual(history.cursorID, ids["B"])
        XCTAssertEqual(history.redo()?.id, ids["C"], "elegir B desde Historial permite rehacer hasta C")
        XCTAssertEqual(history.revision(ids["B"] ?? UUID())?.parentID, ids["A"])
    }

    func testNavigatingDoesNotCreateRevisionsAndKeepsOtherPreferences() throws {
        var (history, ids) = try linearHistory()
        let before = history.count
        try history.navigate(to: ids["A"] ?? UUID())
        XCTAssertEqual(history.count, before)
        XCTAssertEqual(history.redo()?.id, ids["B"], "la ruta preferida llega hasta el destino")
        XCTAssertEqual(history.redo()?.id, ids["C"], "las preferencias fuera de la ruta se conservan")
        XCTAssertThrowsError(try history.navigate(to: UUID()))
    }

    func testEditingFromThePastAddsAChildAndLeavesTheOldFutureIntact() throws {
        var (history, ids) = try linearHistory()
        try history.navigate(to: ids["raíz"] ?? UUID())
        _ = try history.commit(revision("X", state: state(20), offset: 20))
        let root = history.children(of: ids["raíz"] ?? UUID())
        XCTAssertEqual(Set(root.map(\.label)), ["A", "X"])
        XCTAssertEqual(history.revision(ids["C"] ?? UUID())?.label, "C")
        XCTAssertEqual(history.revision(ids["C"] ?? UUID())?.parentID, ids["B"])
    }

    func testCausalOrderComesFromParentsNotFromTheClock() throws {
        var history = PixelHistory(initialState: state(0))
        let first = try history.commit(revision("primero", state: state(1), offset: 100))
        let second = try history.commit(revision("segundo", state: state(2), offset: -500))
        XCTAssertEqual(history.pathToCursor.map(\.id), [history.rootID, first.id, second.id])
        _ = history.undo()
        XCTAssertEqual(history.redo()?.id, second.id)
    }

    // MARK: Validación del grafo

    private func rebuilt(_ edit: (inout [PixelRevision], inout UUID, inout UUID, inout [UUID: UUID]) -> Void) throws -> PixelHistory {
        let (history, _) = try linearHistory()
        var revisions = Array(history.revisions.values)
        var root = history.rootID
        var cursor = history.cursorID
        var preferred = history.preferredChild
        edit(&revisions, &root, &cursor, &preferred)
        return try PixelHistory(revisions: revisions, rootID: root, cursorID: cursor, preferredChild: preferred, bookmarks: [])
    }

    func testGraphValidationRejectsBrokenHistories() throws {
        XCTAssertNoThrow(try rebuilt { _, _, _, _ in })
        XCTAssertThrowsError(try rebuilt { _, _, cursor, _ in cursor = UUID() }, "cursor inexistente")
        XCTAssertThrowsError(try rebuilt { revisions, _, _, _ in revisions[1].parentID = UUID() }, "padre inexistente")
        XCTAssertThrowsError(try rebuilt { revisions, _, _, _ in revisions.append(revisions[0]) }, "ID duplicado")
        XCTAssertThrowsError(try rebuilt { revisions, root, _, _ in
            if let index = revisions.firstIndex(where: { $0.id == root }) { revisions[index].beforeState = revisions[index].afterState }
        }, "la raíz no puede tener estado previo")
        XCTAssertThrowsError(try rebuilt { revisions, _, _, _ in
            for index in revisions.indices where revisions[index].label == "B" { revisions[index].beforeState = state(77) }
        }, "estado previo divergente")
        XCTAssertThrowsError(try rebuilt { revisions, _, _, _ in
            for index in revisions.indices
                where revisions[index].parentID == nil { revisions[index].parentID = revisions.first { $0.label == "C" }?.id }
        }, "ciclo")
        XCTAssertThrowsError(try rebuilt { revisions, _, _, _ in revisions.append(revision("suelta", state: state(5))) }, "dos raíces")
        XCTAssertThrowsError(try rebuilt { _, _, _, preferred in preferred[UUID()] = UUID() }, "preferencia ajena")
    }

    func testBookmarksAreNamedAndValidated() throws {
        var (history, ids) = try linearHistory()
        try history.setBookmark("Antes de colorear", on: ids["B"] ?? UUID())
        XCTAssertEqual(history.bookmarks.count, 1)
        XCTAssertThrowsError(try history.setBookmark("mal\nnombre", on: ids["B"] ?? UUID()))
        XCTAssertThrowsError(try history.setBookmark("x", on: UUID()))
        history.removeBookmark(on: ids["B"] ?? UUID())
        XCTAssertTrue(history.bookmarks.isEmpty)
    }

    // MARK: Presupuesto

    func testBudgetWarnsAtEightyPercentAndRejectsAtTheHardLimit() {
        XCTAssertEqual(PixelHistoryBudget.evaluate(revisions: 10, storageBytes: 0), .ok)
        XCTAssertEqual(PixelHistoryBudget.evaluate(revisions: 80_000, storageBytes: 0), .warning(resource: "revisiones"))
        XCTAssertEqual(PixelHistoryBudget.evaluate(revisions: 99_999, storageBytes: 0), .warning(resource: "revisiones"))
        XCTAssertEqual(PixelHistoryBudget.evaluate(revisions: 100_000, storageBytes: 0), .exceeded(resource: "revisiones"))
        XCTAssertEqual(PixelHistoryBudget.evaluate(revisions: 1, storageBytes: PxaLimits.uncompressedBytes / 10 * 9),
                       .warning(resource: "almacenamiento"))
        XCTAssertEqual(PixelHistoryBudget.evaluate(revisions: 1, storageBytes: PxaLimits.uncompressedBytes),
                       .exceeded(resource: "almacenamiento"))
    }

    func testCommitIsRejectedBeforeChangingAnythingWhenStorageIsFull() throws {
        var (history, _) = try linearHistory()
        let before = history
        XCTAssertThrowsError(try history.commit(revision("no", state: state(40)), storageBytes: PxaLimits.uncompressedBytes)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .capacity)
        }
        XCTAssertEqual(history, before, "la historia existente queda intacta")
    }

    // MARK: Persistencia

    func testHistoryRoundTripsThroughObjectsWithCursorPreferencesAndFocus() throws {
        var (history, ids) = try linearHistory()
        _ = history.undo()
        _ = history.undo()
        let layer = UUID()
        var branch = revision("D", state: state(9), offset: 10)
        branch.affected = PixelAffected(layers: [layer], frames: [UUID()], paletteEntries: [3, 9],
                                        regions: [PixelRegion(layerID: layer, frameID: UUID(), x: 1, y: 2, width: 3, height: 4)])
        branch.source = .codex
        branch.focusBefore = PixelFocus(layerID: layer, frameID: nil, selection: PixelSelection())
        branch.focusAfter = PixelFocus(layerID: layer, frameID: UUID(),
                                       selection: .rectangle(x: 2, y: 2, width: 3, height: 3, canvasWidth: 8, canvasHeight: 8))
        try history.commit(branch)
        _ = history.undo()
        try history.setBookmark("marca", on: ids["A"] ?? UUID())

        let ref = PixelHistoryCodec.encode(history, into: &store)
        let loaded = try PixelHistoryCodec.decode(ref, from: store)
        XCTAssertEqual(loaded, history)
        XCTAssertEqual(loaded.cursorID, history.cursorID)
        XCTAssertTrue(loaded.canRedo, "Rehacer sigue disponible tras guardar y reabrir")
        XCTAssertNil(loaded.revision(branch.id)?.focusBefore.selection?.tiles.first, "selección explícita vacía conservada")
        XCTAssertNotNil(loaded.revision(branch.id)?.focusBefore.selection)
        XCTAssertEqual(PixelHistoryCodec.encode(loaded, into: &store), ref, "codificar es determinista")
    }

    func testDecodeRejectsAnIndexWhoseRevisionDisagreesWithItsID() throws {
        let (history, _) = try linearHistory()
        let ref = PixelHistoryCodec.encode(history, into: &store)
        var objects = store.objects
        let revisionRef = try XCTUnwrap(try store.children(of: ref).first { $0.type == .revision })
        let other = try XCTUnwrap(try store.children(of: ref).last { $0.type == .revision && $0.hash != revisionRef.hash })
        let swapped = try XCTUnwrap(objects[other.hash])
        objects[revisionRef.hash] = swapped
        XCTAssertThrowsError(try PixelHistoryCodec.decode(ref, from: PxaObjectStore(objects: objects)))
    }

    // MARK: Copia reducida

    func testReducedCopyKeepsCurrentStateWithoutBrokenReferences() throws {
        var (history, ids) = try linearHistory()
        try history.setBookmark("B", on: ids["B"] ?? UUID())
        try history.setBookmark("A", on: ids["A"] ?? UUID())
        let (onlyCurrent, mapZero) = try history.reduced(keepingAncestors: 0)
        XCTAssertEqual(onlyCurrent.count, 1)
        XCTAssertEqual(onlyCurrent.currentState, history.currentState)
        XCTAssertNil(onlyCurrent.cursor.parentID)
        XCTAssertNil(onlyCurrent.cursor.beforeState)
        XCTAssertNotEqual(onlyCurrent.cursorID, ids["C"], "se regeneran las identidades")
        XCTAssertEqual(mapZero.count, 1)
        XCTAssertTrue(onlyCurrent.bookmarks.isEmpty, "los marcadores de revisiones omitidas se retiran")

        let (two, map) = try history.reduced(keepingAncestors: 1)
        XCTAssertEqual(two.pathToCursor.map(\.label), ["B", "C"])
        XCTAssertEqual(two.bookmarks.map(\.name), ["B"])
        XCTAssertEqual(two.bookmarks.first?.revisionID, map[ids["B"] ?? UUID()])
        XCTAssertNoThrow(try two.validateGraph())
        XCTAssertEqual(two.revision(two.rootID)?.afterState, history.revision(ids["B"] ?? UUID())?.afterState)

        let (all, _) = try history.reduced(keepingAncestors: 100)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.revision(all.rootID)?.label, "Documento nuevo")
    }

    func testReducedCopyOmitsOtherBranches() throws {
        var (history, ids) = try linearHistory()
        try history.navigate(to: ids["A"] ?? UUID())
        _ = try history.commit(revision("D", state: state(9), offset: 10))
        let (copy, _) = try history.reduced(keepingAncestors: 5)
        XCTAssertEqual(copy.pathToCursor.map(\.label), ["Documento nuevo", "A", "D"])
        XCTAssertEqual(copy.count, 3, "se omiten B y C")
        XCTAssertTrue(copy.otherBranches.isEmpty)
    }
}
