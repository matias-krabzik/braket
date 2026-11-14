@testable import Krabzik
import XCTest

/// Transacciones, alcance, bloqueos y paleta de PXA-03 y PXA-04 §1–§2.
final class PixelArtOperationsTests: XCTestCase {
    private let red = PixelRGBA(255, 0, 0)
    private let blue = PixelRGBA(0, 0, 255)

    /// 40 × 40, dos capas, dos fotogramas y paleta con 7 «piel» y 9 «madera», ambas rojas.
    private func makeCore() throws -> PixelDocumentCore {
        var state = PixelArtState.blank(width: 40, height: 40)
        state.palette.entries = [PaletteEntry(id: 7, name: "piel", color: red), PaletteEntry(id: 9, name: "madera", color: red)]
        state.layers.append(PixelLayer(name: "Detalle"))
        state.frames.append(PixelFrame(duration: 100))
        let base = state.layers[0].id
        var cel = PixelCel()
        cel.setPixel(x: 0, y: 0, to: .linked(7))
        cel.setPixel(x: 1, y: 0, to: .free(red))
        cel.setPixel(x: 2, y: 0, to: .linked(9))
        cel.setPixel(x: 35, y: 35, to: .linked(7))
        state.frames[0].cels[base] = cel
        return try PixelDocumentCore(state: state)
    }

    private func tx(_ core: PixelDocumentCore, source: PixelRevisionSource = .manual, _ operations: [PixelOperation]) -> PixelTransaction {
        tx(core, .document(core.state), source: source, operations)
    }

    private func tx(_ core: PixelDocumentCore, _ scope: PixelScope, source: PixelRevisionSource = .manual,
                    _ operations: [PixelOperation]) -> PixelTransaction {
        PixelTransaction(label: "prueba", operationKind: "test", source: source, scope: scope, operations: operations)
    }

    private func layer(_ core: PixelDocumentCore, _ index: Int) -> UUID { core.state.layers[index].id }
    private func frame(_ core: PixelDocumentCore, _ index: Int) -> UUID { core.state.frames[index].id }

    private func pixel(_ core: PixelDocumentCore, layer: Int = 0, frame: Int = 0, x: Int, y: Int) -> PixelValue {
        core.state.pixel(layer: self.layer(core, layer), frame: self.frame(core, frame), x: x, y: y)
    }

    private func write(_ core: PixelDocumentCore, layer: Int = 0, frame: Int = 0, _ writes: [PixelWrite]) -> PixelOperation {
        .writePixels(layer: self.layer(core, layer), frame: self.frame(core, frame), writes: writes)
    }

    private func render(_ core: PixelDocumentCore, frame: Int = 0) -> PixelBitmap {
        PixelArtRenderer.render(core.state, frame: self.frame(core, frame))
    }

    private func assertRejected(_ core: PixelDocumentCore, _ transaction: PixelTransaction, _ kind: PixelArtError.Kind,
                                file: StaticString = #filePath, line: UInt = #line) {
        var copy = core
        XCTAssertThrowsError(try copy.apply(transaction), file: file, line: line) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, kind, "\(error)", file: file, line: line)
        }
        XCTAssertEqual(copy.state, core.state, "un rechazo no deja cambios", file: file, line: line)
        XCTAssertEqual(copy.history, core.history, file: file, line: line)
    }

    // MARK: Transacciones

    func testApplyCreatesOneRevisionAndUndoRedoRestoreExactStates() throws {
        var core = try makeCore()
        let original = core.state
        let revision = try XCTUnwrap(try core.apply(tx(core, [write(core, [PixelWrite(x: 3, y: 3, value: .free(blue))])])))
        XCTAssertEqual(core.history.count, 2)
        XCTAssertEqual(revision.affected.regions.count, 1)
        XCTAssertEqual(pixel(core, x: 3, y: 3), .free(blue))
        let edited = core.state
        let generation = core.generation
        XCTAssertNotNil(try core.undo())
        XCTAssertEqual(core.state, original)
        XCTAssertGreaterThan(core.generation, generation)
        XCTAssertNotNil(try core.redo())
        XCTAssertEqual(core.state, edited)
        XCTAssertNil(try core.redo())
    }

    func testAnOperationWithoutArtisticDifferenceCreatesNoRevision() throws {
        var core = try makeCore()
        XCTAssertNil(try core.apply(tx(core, [write(core, [PixelWrite(x: 0, y: 0, value: .linked(7))])])))
        XCTAssertNil(try core.apply(tx(core, [])))
        XCTAssertEqual(core.history.count, 1)
        XCTAssertEqual(core.generation, 0)
    }

    func testAHundredOperationsAreOneRevisionAndAFailureAppliesNone() throws {
        var core = try makeCore()
        let writes = (0..<100).map { write(core, [PixelWrite(x: $0 % 40, y: 10 + $0 / 40, value: .free(blue))]) }
        XCTAssertNotNil(try core.apply(tx(core, writes)))
        XCTAssertEqual(core.history.count, 2, "una sola revisión")

        let broken = writes.prefix(98) + [.setFrameDuration(UUID(), milliseconds: 5)] + writes.suffix(1)
        assertRejected(core, tx(core, Array(broken)), .invalid)
    }

    func testStaleBaseIsRejectedAndTheSameTokenCannotApplyTwice() throws {
        var core = try makeCore()
        var transaction = tx(core, [write(core, [PixelWrite(x: 5, y: 5, value: .free(blue))])])
        transaction.base = core.token
        XCTAssertNotNil(try core.apply(transaction))
        assertRejected(core, transaction, .stale)

        var foreign = tx(core, [write(core, [PixelWrite(x: 6, y: 6, value: .free(blue))])])
        foreign.base = PixelBaseToken(instanceID: UUID(), revisionID: core.history.cursorID, stateHash: core.stateRef.hash,
                                      generation: core.generation)
        assertRejected(core, foreign, .stale)

        var viaUndo = tx(core, [write(core, [PixelWrite(x: 6, y: 6, value: .free(blue))])])
        viaUndo.base = core.token
        _ = try core.undo()
        _ = try core.redo()
        assertRejected(core, viaUndo, .stale)
    }

    func testNavigatingRestoresAnyRevisionWithoutCreatingOne() throws {
        var core = try makeCore()
        let root = core.history.rootID
        try core.apply(tx(core, [write(core, [PixelWrite(x: 3, y: 3, value: .free(blue))])]))
        try core.apply(tx(core, [write(core, [PixelWrite(x: 4, y: 4, value: .free(blue))])]))
        let count = core.history.count
        try core.navigate(to: root)
        XCTAssertEqual(pixel(core, x: 3, y: 3), .empty)
        XCTAssertEqual(core.history.count, count)
        XCTAssertTrue(core.history.canRedo)
    }

    // MARK: Alcance

    func testSelectionScopeLimitsWhichPixelsMayChange() throws {
        let core = try makeCore()
        let mask = PixelSelection.rectangle(x: 0, y: 0, width: 4, height: 4, canvasWidth: 40, canvasHeight: 40)
        let scope = PixelScope.selection(mask, layer: layer(core, 0), frame: frame(core, 0))
        var inside = core
        XCTAssertNoThrow(try inside.apply(tx(core, scope, [write(core, [PixelWrite(x: 3, y: 3, value: .free(blue))])])))
        assertRejected(core, tx(core, scope, [write(core, [PixelWrite(x: 4, y: 4, value: .free(blue))])]), .scope)
        assertRejected(core, tx(core, scope, [write(core, layer: 1, [PixelWrite(x: 1, y: 1, value: .free(blue))])]), .scope)
        assertRejected(core, tx(core, scope, [write(core, frame: 1, [PixelWrite(x: 1, y: 1, value: .free(blue))])]), .scope)
        let empty = PixelScope.selection(PixelSelection(), layer: layer(core, 0), frame: frame(core, 0))
        assertRejected(core, tx(core, empty, [write(core, [PixelWrite(x: 1, y: 1, value: .free(blue))])]), .scope)
    }

    func testStructuralChangesNeedDocumentScope() throws {
        let core = try makeCore()
        let scope = PixelScope.layer(layer(core, 0), in: core.state)
        assertRejected(core, tx(core, scope, [.deleteLayer(layer(core, 1))]), .scope)
        assertRejected(core, tx(core, scope, [.setFrameDuration(frame(core, 0), milliseconds: 50)]), .scope)
        assertRejected(core, tx(core, scope, [.resizeCanvas(width: 20, height: 20, offsetX: 0, offsetY: 0)]), .scope)
        var document = core
        XCTAssertNoThrow(try document.apply(tx(core, [.setFrameDuration(frame(core, 0), milliseconds: 50)])))
    }

    func testCreatingALayerInsideAFrameOrSelectionScopeStaysInsideIt() throws {
        let core = try makeCore()
        let newLayer = PixelLayer(name: "Nueva")
        let frameScope = PixelScope.frame(frame(core, 0), in: core.state)
        var allowed = core
        let draw = PixelOperation.writePixels(layer: newLayer.id, frame: frame(core, 0),
                                              writes: [PixelWrite(x: 1, y: 1, value: .free(blue))])
        XCTAssertNoThrow(try allowed.apply(tx(core, frameScope, [.addLayer(newLayer, at: 2), draw])))
        let outside = PixelOperation.writePixels(layer: newLayer.id, frame: frame(core, 1),
                                                 writes: [PixelWrite(x: 1, y: 1, value: .free(blue))])
        assertRejected(core, tx(core, frameScope, [.addLayer(newLayer, at: 2), outside]), .scope)
        assertRejected(core, tx(core, .layer(layer(core, 0), in: core.state), [.addLayer(newLayer, at: 2)]), .scope)
        let mask = PixelSelection.rectangle(x: 0, y: 0, width: 2, height: 2, canvasWidth: 40, canvasHeight: 40)
        let selectionScope = PixelScope.selection(mask, layer: layer(core, 0), frame: frame(core, 0))
        let spill = PixelOperation.writePixels(layer: newLayer.id, frame: frame(core, 0),
                                               writes: [PixelWrite(x: 9, y: 9, value: .free(blue))])
        assertRejected(core, tx(core, selectionScope, [.addLayer(newLayer, at: 2), spill]), .scope)
    }

    func testLayerPropertiesFollowTheirScope() throws {
        let core = try makeCore()
        let only = PixelScope.cel(layer: layer(core, 0), frame: frame(core, 0))
        assertRejected(core, tx(core, only, [.setLayerProperty(layer(core, 0), .opacity(10))]), .scope)
        assertRejected(core, tx(core, only, [.setLayerProperty(layer(core, 1), .name("x"))]), .scope)
        var named = core
        XCTAssertNoThrow(try named.apply(tx(core, only, [.setLayerProperty(layer(core, 0), .name("Fondo"))])))
        var wholeLayer = core
        XCTAssertNoThrow(try wholeLayer.apply(tx(core, .layer(layer(core, 0), in: core.state),
                                                 [.setLayerProperty(layer(core, 0), .opacity(10))])))
    }

    // MARK: Bloqueos de capa

    private func lockedCore() throws -> PixelDocumentCore {
        var core = try makeCore()
        try core.apply(tx(core, [.setLayerProperty(layer(core, 0), .locked(true))]))
        return core
    }

    func testLockedLayerProtectsContentOrderOpacityAndDeletion() throws {
        let core = try lockedCore()
        assertRejected(core, tx(core, [write(core, [PixelWrite(x: 9, y: 9, value: .free(blue))])]), .locked)
        assertRejected(core, tx(core, [.setLayerProperty(layer(core, 0), .opacity(5))]), .locked)
        assertRejected(core, tx(core, [.deleteLayer(layer(core, 0))]), .locked)
        assertRejected(core, tx(core, [.moveLayer(layer(core, 0), to: 1)]), .locked)
        assertRejected(core, tx(core, [.deleteFrame(frame(core, 0))]), .locked)
        assertRejected(core, tx(core, [.resizeCanvas(width: 20, height: 20, offsetX: 0, offsetY: 0)]), .locked)
        var allowed = core
        XCTAssertNoThrow(try allowed.apply(tx(core,
                                              [
                                                  .setLayerProperty(layer(core, 0), .name("Fondo")),
                                                  .setLayerProperty(layer(core, 0), .visible(false))
                                              ])))
        var grow = core
        XCTAssertNoThrow(try grow.apply(tx(core, [.resizeCanvas(width: 60, height: 60, offsetX: 0, offsetY: 0)])),
                         "ampliar no toca sus píxeles")
        var reorder = core
        XCTAssertNoThrow(try reorder.apply(tx(core, [.addLayer(PixelLayer(name: "C"), at: 2), .moveLayer(layer(core, 1), to: 1)])))
    }

    func testUnlockingAndModifyingInTheSameBatchDoesNotEscapeTheLock() throws {
        let core = try lockedCore()
        let batch: [PixelOperation] = [.setLayerProperty(layer(core, 0), .locked(false)),
                                       write(core, [PixelWrite(x: 9, y: 9, value: .free(blue))])]
        assertRejected(core, tx(core, batch), .locked)
        var unlocked = core
        XCTAssertNoThrow(try unlocked.apply(tx(core, [.setLayerProperty(layer(core, 0), .locked(false))])))
        XCTAssertNoThrow(try unlocked.apply(tx(unlocked, [write(unlocked, [PixelWrite(x: 9, y: 9, value: .free(blue))])])))
    }

    func testCodexCannotChangeLocksOrTouchALockedLayer() throws {
        let core = try lockedCore()
        assertRejected(core, tx(core, source: .codex, [.setLayerProperty(layer(core, 0), .locked(false))]), .locked)
        assertRejected(core, tx(core, source: .codex, [.setLayerProperty(layer(core, 1), .locked(true))]), .locked)
        assertRejected(core, tx(core, source: .codex, [.setLayerProperty(layer(core, 0), .name("x"))]), .locked)
        assertRejected(core, tx(core, source: .codex, [.setLayerProperty(layer(core, 0), .visible(false))]), .locked)
        assertRejected(core, tx(core, source: .codex, [.editPaletteEntry(7, name: nil, color: nil, locked: true)]), .locked)
        var visible = core
        XCTAssertNoThrow(try visible.apply(tx(core, source: .codex, [.setLayerProperty(layer(core, 1), .visible(false))])))
    }

    func testAlphaLockKeepsTheAlphaOfEveryPosition() throws {
        var core = try makeCore()
        try core.apply(tx(core, [.setLayerProperty(layer(core, 0), .alphaLocked(true))]))
        assertRejected(core, tx(core, [write(core, [PixelWrite(x: 9, y: 9, value: .free(blue))])]), .locked)
        assertRejected(core, tx(core, [write(core, [PixelWrite(x: 0, y: 0, value: .empty)])]), .locked)
        assertRejected(core, tx(core, [write(core, [PixelWrite(x: 0, y: 0, value: .free(PixelRGBA(0, 0, 255, 128)))])]), .locked)
        var recolor = core
        XCTAssertNoThrow(try recolor.apply(tx(core, [write(core, [PixelWrite(x: 0, y: 0, value: .free(blue))])])))
        XCTAssertEqual(pixel(recolor, x: 0, y: 0), .free(blue))
    }

    // MARK: Paleta (ejemplos normativos de PXA-03 §9)

    func testEditingAnEntryChangesOnlyItsLinkedPixels() throws {
        var core = try makeCore()
        let before = render(core)
        try core.apply(tx(core, [.editPaletteEntry(7, name: nil, color: blue, locked: nil)]))
        let after = render(core)
        XCTAssertEqual(after.pixel(x: 0, y: 0), blue, "vinculado a 7")
        XCTAssertEqual(after.pixel(x: 1, y: 0), red, "libre con el mismo rojo")
        XCTAssertEqual(after.pixel(x: 2, y: 0), red, "ID 9 tiene el mismo rojo y no cambia")
        XCTAssertNotEqual(before, after)
        _ = try core.undo()
        XCTAssertEqual(render(core), before)
    }

    func testReorderingThePaletteChangesNothingVisible() throws {
        var core = try makeCore()
        let before = render(core)
        let usage = core.state.usedPaletteIDs
        try core.apply(tx(core, [.reorderPalette([9, 7])]))
        XCTAssertEqual(render(core), before)
        XCTAssertEqual(core.state.usedPaletteIDs, usage)
        XCTAssertEqual(core.state.palette.entries.map(\.id), [9, 7])
        assertRejected(core, tx(core, [.reorderPalette([9])]), .invalid)
        assertRejected(core, tx(core, [.reorderPalette([9, 7, 3])]), .invalid)
    }

    func testChangingAnEntryGloballyAffectsEveryFrameThatSharesThePalette() throws {
        var core = try makeCore()
        let newFrame = UUID()
        try core.apply(tx(core, [.duplicateFrame(frame(core, 0), newID: newFrame, at: 1)]))
        try core.apply(tx(core, [.editPaletteEntry(7, name: nil, color: blue, locked: nil)]))
        for index in 0...1 { XCTAssertEqual(render(core, frame: index).pixel(x: 0, y: 0), blue) }
        XCTAssertEqual(core.state.frames[1].id, newFrame)
        try core.apply(tx(core, [write(core, frame: 1, [PixelWrite(x: 0, y: 0, value: .free(red))])]))
        XCTAssertEqual(pixel(core, frame: 0, x: 0, y: 0), .linked(7), "pintar la copia no cambia la original")
        XCTAssertEqual(pixel(core, frame: 1, x: 0, y: 0), .free(red))
    }

    func testEditingAnEntryNeedsDocumentScope() throws {
        let core = try makeCore()
        assertRejected(core, tx(core, .layer(layer(core, 0), in: core.state), [.editPaletteEntry(7, name: nil, color: blue, locked: nil)]),
                       .scope)
        assertRejected(core, tx(core, .layer(layer(core, 0), in: core.state), [.deletePaletteEntry(7, removal: .unlink)]), .scope)
        var rename = core
        XCTAssertThrowsError(try rename.apply(tx(core, .layer(layer(core, 0), in: core.state),
                                                 [.editPaletteEntry(7, name: "x", color: nil, locked: nil)])))
    }

    func testRecoloringASelectionUsesANewIDAndLeavesTheOriginalOutside() throws {
        var core = try makeCore()
        let ids = try core.reserveEntryIDs(1)
        let mask = PixelSelection.rectangle(x: 0, y: 0, width: 8, height: 8, canvasWidth: 40, canvasHeight: 40)
        let scope = PixelScope.selection(mask, layer: layer(core, 0), frame: frame(core, 0))
        let entry = PaletteEntry(id: ids[0], name: "piel nocturna", color: blue)
        try core.apply(tx(core, scope, [.recolorLinked(source: 7, newEntry: entry)]))
        XCTAssertEqual(pixel(core, x: 0, y: 0), .linked(ids[0]))
        XCTAssertEqual(pixel(core, x: 35, y: 35), .linked(7), "ID 7 intacto fuera de la selección")
        XCTAssertEqual(core.state.palette.entry(7)?.color, red)
        XCTAssertEqual(PixelPaletteTools.usages(in: core.state)[ids[0]]?.pixelCount, 1)
    }

    func testDeletingAnEntryWithUsesNeedsAReplacementAndUndoRestoresItsID() throws {
        var core = try makeCore()
        assertRejected(core, tx(core, [.deletePaletteEntry(7, removal: .requireUnused)]), .invalid)
        try core.apply(tx(core, [.deletePaletteEntry(7, removal: .unlink)]))
        XCTAssertEqual(pixel(core, x: 0, y: 0), .free(red), "queda libre con el RGBA anterior")
        XCTAssertNil(core.state.palette.entry(7))
        _ = try core.undo()
        XCTAssertEqual(pixel(core, x: 0, y: 0), .linked(7), "deshacer recupera el vínculo, no una aproximación por color")
        try core.apply(tx(core, [.deletePaletteEntry(7, removal: .reassign(to: 9))]))
        XCTAssertEqual(pixel(core, x: 0, y: 0), .linked(9))
        XCTAssertEqual(pixel(core, x: 35, y: 35), .linked(9))
        var unused = core
        try unused.apply(tx(unused, [.addPaletteEntry(PaletteEntry(id: try unused.reserveEntryIDs(1)[0], color: blue))]))
        XCTAssertNoThrow(try unused.apply(tx(unused, [.deletePaletteEntry(unused.state.palette.entries[1].id, removal: .requireUnused)])))
    }

    func testAlphaZeroEntryKeepsItsUsesAndTheyReappearWhenTheAlphaRises() throws {
        var core = try makeCore()
        try core.apply(tx(core, [.editPaletteEntry(7, name: nil, color: PixelRGBA(255, 0, 0, 0), locked: nil)]))
        XCTAssertEqual(render(core).pixel(x: 0, y: 0).alpha, 0)
        XCTAssertEqual(pixel(core, x: 0, y: 0), .linked(7), "el vínculo se conserva")
        try core.apply(tx(core, [.editPaletteEntry(7, name: nil, color: PixelRGBA(255, 0, 0, 255), locked: nil)]))
        XCTAssertEqual(render(core).pixel(x: 0, y: 0).alpha, 255)
        XCTAssertEqual(render(core).pixel(x: 5, y: 5).alpha, 0, "los píxeles vacíos no reaparecen")
    }

    func testLockedEntriesCannotBeEditedDeletedOrSubstitutedButCanPaint() throws {
        var core = try makeCore()
        try core.apply(tx(core, [.editPaletteEntry(7, name: nil, color: nil, locked: true)]))
        assertRejected(core, tx(core, [.editPaletteEntry(7, name: nil, color: blue, locked: nil)]), .locked)
        assertRejected(core, tx(core, [.editPaletteEntry(7, name: "otro", color: nil, locked: nil)]), .locked)
        assertRejected(core, tx(core, [.deletePaletteEntry(7, removal: .unlink)]), .locked)
        assertRejected(core, tx(core, [.mergePaletteEntries(keep: 9, remove: [7])]), .locked)
        XCTAssertNoThrow(try core.apply(tx(core, [write(core, [PixelWrite(x: 9, y: 9, value: .linked(7))])])), "pintar con ella sí")
    }

    func testEntriesUsedByAProtectedLayerCannotChange() throws {
        var locked = try makeCore()
        try locked.apply(tx(locked, [.setLayerProperty(layer(locked, 0), .locked(true))]))
        assertRejected(locked, tx(locked, [.editPaletteEntry(7, name: nil, color: blue, locked: nil)]), .locked)
        assertRejected(locked, tx(locked, source: .codex, [.editPaletteEntry(7, name: nil, color: blue, locked: nil)]), .locked)
        var rename = locked
        XCTAssertNoThrow(try rename.apply(tx(locked, [.editPaletteEntry(7, name: "solo nombre", color: nil, locked: nil)])),
                         "renombrar no se bloquea")

        var alpha = try makeCore()
        try alpha.apply(tx(alpha, [.setLayerProperty(layer(alpha, 0), .alphaLocked(true))]))
        assertRejected(alpha, tx(alpha, [.editPaletteEntry(7, name: nil, color: PixelRGBA(255, 0, 0, 100), locked: nil)]), .locked)
        XCTAssertNoThrow(try alpha.apply(tx(alpha, [.editPaletteEntry(7, name: nil, color: blue, locked: nil)])),
                         "cambiar RGB conserva el alfa")
    }

    func testPaletteCapacityIsEvaluatedOnTheFinalState() throws {
        var state = PixelArtState.blank(width: 4, height: 4)
        state.palette.entries = (1...256).map { PaletteEntry(id: UInt32($0), color: PixelRGBA(UInt8($0 % 256), 0, 0)) }
        var core = try PixelDocumentCore(state: state)
        let ids = try core.reserveEntryIDs(1)
        assertRejected(core, tx(core, [.addPaletteEntry(PaletteEntry(id: ids[0], color: blue))]), .limit)
        try core.apply(tx(core, [.deletePaletteEntry(1, removal: .requireUnused), .addPaletteEntry(PaletteEntry(id: ids[0], color: blue))]))
        XCTAssertEqual(core.state.palette.entries.count, 256)
    }

    func testPaletteIDsAreMonotonicAndNeverReused() throws {
        var core = try makeCore()
        XCTAssertEqual(core.nextPaletteEntryID, 10)
        let ids = try core.reserveEntryIDs(2)
        XCTAssertEqual(ids, [10, 11])
        assertRejected(core, tx(core, [.addPaletteEntry(PaletteEntry(id: 50, color: blue))]), .invalid)
        assertRejected(core, tx(core, [.addPaletteEntry(PaletteEntry(id: 7, color: blue))]), .invalid)
        try core.apply(tx(core, [.addPaletteEntry(PaletteEntry(id: ids[0], color: blue))]))
        _ = try core.undo()
        XCTAssertEqual(core.nextPaletteEntryID, 12, "deshacer no rebobina el asignador")
        assertRejected(core, tx(core, [.addPaletteEntry(PaletteEntry(id: ids[0], color: red))]), .invalid)
        XCTAssertNoThrow(try core.apply(tx(core, [.addPaletteEntry(PaletteEntry(id: ids[1], color: red))])))
    }

    func testExhaustedIDRangeIsRejectedExplicitly() throws {
        var state = PixelArtState.blank(width: 4, height: 4)
        state.palette.entries = [PaletteEntry(id: 4_294_967_293, color: red)]
        var core = try PixelDocumentCore(state: state)
        XCTAssertEqual(try core.reserveEntryIDs(1), [4_294_967_294])
        XCTAssertEqual(core.nextPaletteEntryID, 4_294_967_295)
        XCTAssertThrowsError(try core.reserveEntryIDs(1)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .capacity)
        }
        XCTAssertEqual(try core.reserveEntryIDs(0), [])
    }

    func testMergeReassignsUsesAndShowsTheVisualChangeWhenColorsDiffer() throws {
        var core = try makeCore()
        try core.apply(tx(core, [.editPaletteEntry(9, name: nil, color: blue, locked: nil)]))
        let before = render(core)
        try core.apply(tx(core, [.mergePaletteEntries(keep: 7, remove: [9])]))
        XCTAssertNil(core.state.palette.entry(9))
        XCTAssertEqual(pixel(core, x: 2, y: 0), .linked(7))
        XCTAssertNotEqual(render(core), before, "la fusión cambió el aspecto de los usos de 9")
        assertRejected(core, tx(core, [.mergePaletteEntries(keep: 7, remove: [7])]), .invalid)
    }

    func testPixelConversionsBetweenFreeAndLinked() throws {
        var core = try makeCore()
        let all = PixelScope.document(core.state)
        try core.apply(tx(core, all, [.linkExactMatches(color: red, entry: 9)]))
        XCTAssertEqual(pixel(core, x: 1, y: 0), .linked(9), "el rojo libre pasa a la entrada elegida")
        XCTAssertEqual(pixel(core, x: 0, y: 0), .linked(7), "lo ya vinculado no se toca")
        try core.apply(tx(core, all, [.unlinkPixels]))
        XCTAssertEqual(pixel(core, x: 0, y: 0), .free(red))
        XCTAssertEqual(pixel(core, x: 35, y: 35), .free(red))
        XCTAssertTrue(core.state.usedPaletteIDs.isEmpty)
        _ = try core.undo()
        XCTAssertEqual(pixel(core, x: 0, y: 0), .linked(7), "deshacer recupera IDs y clases originales")
    }

    func testReplacingPaletteColorsKeepsIdentitiesAndLeavesFreePixelsAlone() throws {
        var core = try makeCore()
        try core.apply(tx(core, [.replacePaletteColors([7: blue])]))
        XCTAssertEqual(core.state.palette.entries.map(\.id), [7, 9])
        XCTAssertEqual(core.state.palette.entry(9)?.color, red, "lo omitido conserva su valor")
        XCTAssertEqual(pixel(core, x: 1, y: 0), .free(red))
        assertRejected(core, tx(core, [.replacePaletteColors([99: blue])]), .invalid)
    }

    // MARK: Adaptación y extracción

    func testAdaptingPixelsToATargetPaletteIsExplicitAndComplete() throws {
        var core = try makeCore()
        let dark = PixelRGBA(40, 0, 0)
        let ids = try core.reserveEntryIDs(1)
        let scope = PixelScope.document(core.state)
        let plan = try PixelPaletteTools.automaticAdaptation(of: core.state, scope: scope,
                                                             targets: [
                                                                 PaletteEntry(id: ids[0], color: dark),
                                                                 PaletteEntry(id: 7, color: red)
                                                             ])
        XCTAssertEqual(plan.table[red], .linked(7), "el rojo exacto está más cerca de la entrada roja")
        XCTAssertEqual(plan.appearanceChanges, 0)
        XCTAssertEqual(plan.linkOnlyChanges, 2, "la libre y la que apunta a 9 pasan a 7")

        try core.apply(tx(core, scope, [.addPaletteEntry(PaletteEntry(id: ids[0], color: dark)), .adaptPixels([red: .linked(ids[0])])]))
        XCTAssertEqual(pixel(core, x: 0, y: 0), .linked(ids[0]))
        XCTAssertEqual(pixel(core, x: 1, y: 0), .linked(ids[0]))
        assertRejected(core, tx(core, scope, [.adaptPixels([:])]), .invalid)
    }

    func testAutomaticAdaptationBreaksTiesWithTheLowerID() throws {
        var state = PixelArtState.blank(width: 2, height: 1)
        state.frames[0].cels[state.layers[0].id] = {
            var cel = PixelCel()
            cel.setPixel(x: 0, y: 0, to: .free(PixelRGBA(100, 100, 100)))
            return cel
        }()
        let scope = PixelScope.document(state)
        let targets = [PaletteEntry(id: 9, color: PixelRGBA(110, 110, 110)), PaletteEntry(id: 3, color: PixelRGBA(110, 110, 110))]
        let plan = try PixelPaletteTools.automaticAdaptation(of: state, scope: scope, targets: targets)
        XCTAssertEqual(plan.table[PixelRGBA(100, 100, 100)], .linked(3))
        let manual = try PixelPaletteTools.automaticAdaptation(of: state, scope: scope, targets: targets,
                                                               overrides: [PixelRGBA(100, 100, 100): 9])
        XCTAssertEqual(manual.table[PixelRGBA(100, 100, 100)], .linked(9), "la correspondencia manual tiene prioridad")
        XCTAssertThrowsError(try PixelPaletteTools.automaticAdaptation(of: state, scope: scope, targets: targets,
                                                                       overrides: [PixelRGBA(100, 100, 100): 77]))
    }

    func testAdaptationWithAlphaLockOnlyAllowsTargetsThatKeepTheAlpha() throws {
        var state = PixelArtState.blank(width: 2, height: 1)
        state.layers[0].alphaLocked = true
        state.frames[0].cels[state.layers[0].id] = {
            var cel = PixelCel()
            cel.setPixel(x: 0, y: 0, to: .free(PixelRGBA(100, 0, 0, 128)))
            return cel
        }()
        let scope = PixelScope.document(state)
        XCTAssertThrowsError(try PixelPaletteTools.automaticAdaptation(of: state, scope: scope,
                                                                       targets: [PaletteEntry(id: 1,
                                                                                              color: PixelRGBA(100, 0, 0,
                                                                                                               255))])) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .locked)
        }
        let plan = try PixelPaletteTools.automaticAdaptation(of: state, scope: scope, targets: [
            PaletteEntry(id: 1, color: PixelRGBA(100, 0, 0, 255)),
            PaletteEntry(id: 2, color: PixelRGBA(0, 90, 0, 128))
        ])
        XCTAssertEqual(plan.table[PixelRGBA(100, 0, 0, 128)], .linked(2))
        XCTAssertFalse(plan.changesAlpha)
    }

    func testAlphaZeroLinksBecomeEmptyOnlyWhenNoTransparentTargetExistsAndSaysSo() throws {
        var state = PixelArtState.blank(width: 2, height: 1)
        state.palette.entries = [PaletteEntry(id: 1, color: PixelRGBA(0, 0, 0, 0))]
        state.frames[0].cels[state.layers[0].id] = {
            var cel = PixelCel()
            cel.setPixel(x: 0, y: 0, to: .linked(1))
            return cel
        }()
        let scope = PixelScope.document(state)
        let withTransparent = try PixelPaletteTools.automaticAdaptation(of: state, scope: scope,
                                                                        targets: [PaletteEntry(id: 4, color: PixelRGBA(0, 0, 0, 0))])
        XCTAssertEqual(withTransparent.table.values.first, .linked(4))
        XCTAssertTrue(withTransparent.becomesEmpty.isEmpty)
        let without = try PixelPaletteTools.automaticAdaptation(of: state, scope: scope, targets: [PaletteEntry(id: 2, color: red)])
        XCTAssertEqual(without.becomesEmpty, [PixelRGBA(0, 0, 0, 0)])
    }

    func testExtractingAPaletteOrdersByFrequencyThenRGBA() throws {
        var state = PixelArtState.blank(width: 4, height: 1)
        state.frames[0].cels[state.layers[0].id] = {
            var cel = PixelCel()
            cel.setPixel(x: 0, y: 0, to: .free(blue))
            cel.setPixel(x: 1, y: 0, to: .free(red))
            cel.setPixel(x: 2, y: 0, to: .free(red))
            cel.setPixel(x: 3, y: 0, to: .free(PixelRGBA(0, 255, 0)))
            return cel
        }()
        XCTAssertEqual(try PixelPaletteTools.extractPalette(from: state), [red, blue, PixelRGBA(0, 255, 0)],
                       "empate: 0,0,255 precede a 0,255,0")
        var many = PixelArtState.blank(width: 300, height: 1)
        many.frames[0].cels[many.layers[0].id] = {
            var cel = PixelCel()
            for x in 0..<300 { cel.setPixel(x: x, y: 0, to: .free(PixelRGBA(UInt8(x % 256), UInt8(x / 256), 1))) }
            return cel
        }()
        XCTAssertThrowsError(try PixelPaletteTools.extractPalette(from: many)) { error in
            XCTAssertEqual((error as? PixelArtError)?.kind, .capacity)
        }
    }

    // MARK: Documento y secuencias

    func testDeletingAFrameRetiresItFromSequencesAndUndoRestoresBoth() throws {
        var core = try makeCore()
        let sequence = PixelSequence(name: "Solo B", frameIDs: [frame(core, 1)])
        let both = PixelSequence(name: "Ambos", frameIDs: core.state.frames.map(\.id))
        try core.apply(tx(core, [.addSequence(sequence), .addSequence(both)]))
        let withSequences = core.state
        try core.apply(tx(core, [.deleteFrame(frame(core, 1))]))
        XCTAssertEqual(core.state.sequences.map(\.name), ["Ambos"], "la secuencia que quedó vacía se elimina")
        XCTAssertEqual(core.state.sequences[0].frameIDs.count, 1)
        _ = try core.undo()
        XCTAssertEqual(core.state, withSequences)
        assertRejected(core, tx(core, [.deleteFrame(frame(core, 0)), .deleteFrame(frame(core, 1))]), .invalid)
    }

    func testResizingMovesContentAndDropsWhatFallsOutside() throws {
        var core = try makeCore()
        try core.apply(tx(core, [.resizeCanvas(width: 30, height: 30, offsetX: 1, offsetY: 2)]))
        XCTAssertEqual(core.state.width, 30)
        XCTAssertEqual(pixel(core, x: 1, y: 2), .linked(7))
        XCTAssertEqual(pixel(core, x: 2, y: 2), .free(red))
        XCTAssertEqual(core.state.frames[0].cels[layer(core, 0)]?.tiles.count, 1, "el píxel de (35, 35) quedó fuera")
        _ = try core.undo()
        XCTAssertEqual(pixel(core, x: 35, y: 35), .linked(7), "deshacer recupera lo recortado")
        assertRejected(core, tx(core, [.resizeCanvas(width: 5_000, height: 5, offsetX: 0, offsetY: 0)]), .limit)
    }

    func testStateRoundTripsThroughTheStoreAfterManyOperations() throws {
        var core = try makeCore()
        try core.apply(tx(core,
                          [
                              .editPaletteEntry(7, name: nil, color: blue, locked: nil),
                              write(core, [PixelWrite(x: 3, y: 3, value: .linked(9))])
                          ]))
        try core.apply(tx(core, [.duplicateLayer(layer(core, 0), newID: UUID(), name: "Copia")]))
        let revisions = core.history.pathToCursor
        for revision in revisions {
            let decoded = try PixelArtStateCodec.decode(revision.afterState, from: core.store)
            XCTAssertNoThrow(try decoded.validate())
        }
        XCTAssertEqual(try PixelArtStateCodec.decode(core.stateRef, from: core.store), core.state)
    }
}
