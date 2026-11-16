@testable import Krabzik
import XCTest

/// Recuperación local por trabajo (PXA-08): identidad propia que sobrevive a un cambio de ruta, índice versionado,
/// dos generaciones, cortes en cada fase, descarte durable y matriz de decisiones.
final class PixelArtRecoveryTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/")
    private var store = PixelArtRecoveryStore(directory: URL(fileURLWithPath: "/"))
    private let owner = UUID()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recuperacion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PixelArtRecoveryStore(directory: directory.appendingPathComponent("raiz"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func document(duration: Int = 100) throws -> PixelArtDocument {
        var document = try PixelArtDocument(width: 16, height: 16)
        try document.core.apply(PixelTransaction(label: "d", operationKind: "t", scope: .document(document.state),
                                                 operations: [.setFrameDuration(document.state.frames[0].id, milliseconds: duration)]))
        return document
    }

    private func begin(_ name: String = "a.pxa", base: PixelArtFileFingerprint? = nil, draft: Bool = false,
                       documentID: UUID = UUID(), owner: UUID? = nil) throws -> PixelArtRecoveryRecord {
        try store.begin(documentID: documentID, suggestedName: name,
                        originalURL: draft ? nil : directory.appendingPathComponent(name), context: .loosePixelArt,
                        base: base ?? PixelArtFileFingerprint(of: Data(name.utf8)), owner: owner ?? self.owner)
    }

    @discardableResult
    private func capture(_ record: PixelArtRecoveryRecord, generation: Int, duration: Int = 100,
                         changeClass: PixelArtChangeClass = .content, owner: UUID? = nil) throws -> PixelArtRecoverySnapshot {
        try store.capture(try PixelArtFile.snapshot(of: try document(duration: duration)), recoveryID: record.recoveryID,
                          owner: owner ?? self.owner, generation: generation, changeClass: changeClass)
    }

    private func duration(of snapshot: PixelArtRecoverySnapshot, in record: PixelArtRecoveryRecord) throws -> Int {
        try store.load(snapshot, of: record.recoveryID).document.state.frames[0].duration
    }

    // MARK: Identidad

    func testRecoveryIdentitySurvivesARelocationAndIsNotDerivedFromThePath() throws {
        let record = try begin("a.pxa")
        try capture(record, generation: 1, duration: 101)
        let moved = directory.appendingPathComponent("carpeta/b.pxa")
        try store.relocate(record.recoveryID, to: moved, owner: owner)
        let after = try store.readRecord(record.recoveryID)
        XCTAssertEqual(after.recoveryID, record.recoveryID, "renombrar no cambia la identidad")
        XCTAssertEqual(after.originalPath, moved.standardizedFileURL.path)
        XCTAssertEqual(after.snapshots.count, 1, "las generaciones siguen asociadas")
        XCTAssertEqual(try duration(of: after.snapshots[0], in: after), 101)
    }

    func testTwoWorksWithTheSameDocumentIDAndNameKeepSeparateRecoveries() throws {
        let sharedID = UUID()
        let first = try begin("dibujo.pxa", documentID: sharedID)
        let second = try begin("dibujo.pxa", documentID: sharedID)
        XCTAssertNotEqual(first.recoveryID, second.recoveryID)
        try capture(first, generation: 1, duration: 111)
        try capture(second, generation: 1, duration: 222)
        let listing = store.list()
        XCTAssertEqual(listing.records.count, 2)
        for record in listing.records {
            let expected = record.recoveryID == first.recoveryID ? 111 : 222
            XCTAssertEqual(try duration(of: record.snapshots[0], in: record), expected, "nunca se intercambian")
        }
        try store.discard(first.recoveryID)
        XCTAssertEqual(try duration(of: try store.readRecord(second.recoveryID).snapshots[0], in: second), 222)
    }

    // MARK: Generaciones y cortes

    func testKeepsTheTwoLatestGenerationsAndRetiresTheOldestOnlyAfterTheNewOneIsIndexed() throws {
        let record = try begin()
        for generation in 1...3 { try capture(record, generation: generation, duration: 100 + generation) }
        let current = try store.readRecord(record.recoveryID)
        XCTAssertEqual(current.snapshots.map(\.generation), [3, 2])
        XCTAssertEqual(try duration(of: current.snapshots[0], in: current), 103)
        XCTAssertEqual(try duration(of: current.snapshots[1], in: current), 102)
        let files = try FileManager.default
            .contentsOfDirectory(atPath: directory.appendingPathComponent("raiz/\(record.recoveryID.uuidString)").path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".pxa") }.count, 2, "la tercera generación ya no ocupa disco")
        XCTAssertEqual(try store.load(current.snapshots[0], of: record.recoveryID).document.core.history.count, 2)
    }

    func testACutInAnyPhaseLeavesTheLastValidGenerationAvailable() throws {
        struct Cut: Error {}
        for phase in PixelArtRecoveryPhase.allCases where phase != .removeFiles {
            let record = try begin("fase-\(phase).pxa")
            try capture(record, generation: 1, duration: 120)
            try capture(record, generation: 2, duration: 121)
            var cutting = store
            cutting.faults = { reached in if reached == phase { throw Cut() } }
            XCTAssertThrowsError(try cutting.capture(try PixelArtFile.snapshot(of: try document(duration: 123)),
                                                     recoveryID: record.recoveryID, owner: owner, generation: 3,
                                                     changeClass: .content), "\(phase)")
            let after = try store.readRecord(record.recoveryID)
            let valid = store.validSnapshots(of: after)
            XCTAssertFalse(valid.isEmpty, "queda al menos una generación válida tras cortar en \(phase)")
            for snapshot in valid { XCTAssertNoThrow(try store.load(snapshot, of: record.recoveryID), "\(phase)") }
            XCTAssertGreaterThanOrEqual(valid.first?.generation ?? 0, 1)
            XCTAssertNoThrow(try capture(record, generation: 4, duration: 124), "una captura posterior funciona tras \(phase)")
            XCTAssertEqual(try store.readRecord(record.recoveryID).snapshots.first?.generation, 4)
        }
    }

    func testAnUnreferencedFileIsNotOfferedAutomaticallyButCanBeAnalysedExplicitly() throws {
        struct Cut: Error {}
        let record = try begin()
        try capture(record, generation: 1, duration: 130)
        var cutting = store
        cutting.faults = { phase in if phase == .writeIndex { throw Cut() } }
        XCTAssertThrowsError(try cutting.capture(try PixelArtFile.snapshot(of: try document(duration: 131)),
                                                 recoveryID: record.recoveryID, owner: owner, generation: 2, changeClass: .content))
        let current = try store.readRecord(record.recoveryID)
        XCTAssertEqual(current.snapshots.map(\.generation), [1], "el huérfano no entra al índice")
        let orphans = try store.orphanFiles(of: record.recoveryID)
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(try store.loadOrphan(orphans[0], of: record.recoveryID).state.frames[0].duration, 131)
        XCTAssertEqual(try duration(of: current.snapshots[0], in: current), 130, "no pisó la más nueva indexada")
    }

    func testGenerationsMustGrowAndOnlyTheOwnerMayWrite() throws {
        let record = try begin()
        try capture(record, generation: 5)
        XCTAssertThrowsError(try capture(record, generation: 5)) { XCTAssertEqual(($0 as? PixelArtError)?.kind, .stale) }
        XCTAssertThrowsError(try capture(record, generation: 3)) { XCTAssertEqual(($0 as? PixelArtError)?.kind, .stale) }
        XCTAssertThrowsError(try capture(record, generation: 6, owner: UUID())) { XCTAssertEqual(($0 as? PixelArtError)?.kind, .conflict) }
        let newOwner = UUID()
        try store.claim(record.recoveryID, newOwner: newOwner)
        XCTAssertThrowsError(try capture(record, generation: 6), "la sesión anterior ya no es propietaria") {
            XCTAssertEqual(($0 as? PixelArtError)?.kind, .conflict)
        }
        XCTAssertNoThrow(try capture(record, generation: 6, owner: newOwner))
    }

    func testLowDiskSpaceKeepsTheValidGenerationsAndReportsCapacity() throws {
        let record = try begin()
        try capture(record, generation: 1, duration: 140)
        var starved = store
        starved.availableCapacity = { _ in 1_024 }
        XCTAssertThrowsError(try starved.capture(try PixelArtFile.snapshot(of: try document(duration: 141)),
                                                 recoveryID: record.recoveryID, owner: owner, generation: 2,
                                                 changeClass: .content)) { XCTAssertEqual(($0 as? PixelArtError)?.kind, .capacity) }
        XCTAssertEqual(try store.readRecord(record.recoveryID).snapshots.map(\.generation), [1])
    }

    // MARK: Guardado, descarte y caídas

    func testAnExplicitSaveRetiresWhatItCoversAndFlagsLaterGenerationsFromAnotherSession() throws {
        let record = try begin()
        try capture(record, generation: 1)
        try capture(record, generation: 2)
        let successor = UUID()
        try store.claim(record.recoveryID, newOwner: successor)
        try capture(record, generation: 3, owner: successor)
        let saved = PixelArtFileFingerprint(of: Data("guardado".utf8))
        try store.markSaved(record.recoveryID, owner: successor, throughGeneration: 2, newBase: saved)
        let after = try store.readRecord(record.recoveryID)
        XCTAssertEqual(after.snapshots.map(\.generation), [3], "se conserva lo posterior al guardado")
        XCTAssertEqual(after.baseFingerprint, saved)
        XCTAssertEqual(after.lastSavedGeneration, 2)
        XCTAssertFalse(after.snapshots[0].independent, "la misma sesión que guarda continúa la cadena")

        let other = try begin("otra.pxa")
        try capture(other, generation: 1)
        try capture(other, generation: 2)
        try store.claim(other.recoveryID, newOwner: successor)
        try store.markSaved(other.recoveryID, owner: successor, throughGeneration: 1, newBase: saved)
        XCTAssertTrue(try store.readRecord(other.recoveryID).snapshots[0].independent,
                      "una generación de otra sesión no se puede demostrar parte de la cadena: se recupera como copia")
    }

    func testDiscardIsRecordedBeforeDeletingSoACrashDuringCleanupDoesNotResurrectIt() throws {
        struct Crash: Error {}
        let record = try begin()
        try capture(record, generation: 1)
        var crashing = store
        crashing.faults = { phase in if phase == .removeFiles { throw Crash() } }
        XCTAssertThrowsError(try crashing.discard(record.recoveryID))
        XCTAssertEqual(try store.readRecord(record.recoveryID).status, .discarded, "el descarte ya quedó registrado")
        XCTAssertTrue(store.list().records.isEmpty, "no se vuelve a ofrecer")
        XCTAssertEqual(store.purgeDiscarded(), 1)
        XCTAssertFalse(FileManager.default
            .fileExists(atPath: directory.appendingPathComponent("raiz/\(record.recoveryID.uuidString)").path))
        XCTAssertNoThrow(try store.discard(record.recoveryID), "descartar de nuevo no falla")
    }

    func testADiscardDoesNotTouchNewerWorkCapturedByAReplacingSession() throws {
        let record = try begin()
        try capture(record, generation: 1)
        try capture(record, generation: 2)
        XCTAssertThrowsError(try store.discard(record.recoveryID, owner: owner, ifNothingNewerThan: 1)) {
            XCTAssertEqual(($0 as? PixelArtError)?.kind, .conflict)
        }
        XCTAssertThrowsError(try store.discard(record.recoveryID, owner: UUID(), ifNothingNewerThan: 2))
        XCTAssertEqual(try store.readRecord(record.recoveryID).status, .active)
        XCTAssertNoThrow(try store.discard(record.recoveryID, owner: owner, ifNothingNewerThan: 2))
    }

    func testASaveFollowedByACrashBeforeCleanupIsNotOfferedAsLostWork() throws {
        let record = try begin()
        let snapshot = try PixelArtFile.snapshot(of: try document(duration: 150))
        try store.capture(snapshot, recoveryID: record.recoveryID, owner: owner, generation: 1, changeClass: .content)
        let onDisk = PixelArtFileFingerprint(of: snapshot.data)
        let current = try store.readRecord(record.recoveryID)
        XCTAssertTrue(PixelArtRecoveryPlanner.isAlreadyOnDisk(current, current: onDisk))
        XCTAssertFalse(PixelArtRecoveryPlanner.isAlreadyOnDisk(current, current: PixelArtFileFingerprint(of: Data("otro".utf8))),
                       "sin pruebas de equivalencia se conserva el candidato")
        XCTAssertFalse(PixelArtRecoveryPlanner.isAlreadyOnDisk(current, current: nil))
    }

    // MARK: Integridad y entradas hostiles

    func testAMalformedIndexIsReportedNotDeletedAndDoesNotHideOtherWork() throws {
        let good = try begin("bueno.pxa")
        try capture(good, generation: 1)
        let broken = try begin("roto.pxa")
        let brokenFolder = directory.appendingPathComponent("raiz/\(broken.recoveryID.uuidString)")
        try Data("{ no es json".utf8).write(to: brokenFolder.appendingPathComponent("index.json"))
        let future = try begin("futuro.pxa")
        let futureIndex = directory.appendingPathComponent("raiz/\(future.recoveryID.uuidString)/index.json")
        let futureText = try String(contentsOf: futureIndex, encoding: .utf8).replacingOccurrences(of: "\"version\":1",
                                                                                                   with: "\"version\":9")
        try Data(futureText.utf8).write(to: futureIndex)
        try Data("x".utf8).write(to: directory.appendingPathComponent("raiz/no-es-un-id"))

        let listing = store.list()
        XCTAssertEqual(listing.records.map(\.recoveryID), [good.recoveryID])
        XCTAssertEqual(listing.problems.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: brokenFolder.path), "no se elimina como si fuera un descarte")
        XCTAssertTrue(FileManager.default.fileExists(atPath: futureIndex.path))
        XCTAssertThrowsError(try store.readRecord(future.recoveryID)) { XCTAssertEqual(($0 as? PixelArtError)?.kind, .unsupported) }
        XCTAssertThrowsError(try store.removeUnreadable(good.recoveryID), "solo se elimina lo que no se puede leer")
        XCTAssertNoThrow(try store.removeUnreadable(broken.recoveryID))
    }

    func testAnIndexCannotPointOutsideItsFolderOrClaimAnotherIdentity() throws {
        let record = try begin()
        try capture(record, generation: 1)
        let indexURL = directory.appendingPathComponent("raiz/\(record.recoveryID.uuidString)/index.json")
        let original = try String(contentsOf: indexURL, encoding: .utf8)
        let fileName = try XCTUnwrap(try store.readRecord(record.recoveryID).snapshots.first?.fileName)
        for hostile in ["../index.json", "/etc/passwd", "g1-x.pxa", "sub/g1-\(UUID().uuidString).pxa", ""] {
            try Data(original.replacingOccurrences(of: fileName, with: hostile).utf8).write(to: indexURL)
            XCTAssertThrowsError(try store.readRecord(record.recoveryID), "«\(hostile)»")
        }
        try Data(original.replacingOccurrences(of: record.recoveryID.uuidString, with: UUID().uuidString).utf8).write(to: indexURL)
        XCTAssertThrowsError(try store.readRecord(record.recoveryID), "otra identidad")
        try Data(original.utf8).write(to: indexURL)
        XCTAssertNoThrow(try store.readRecord(record.recoveryID))
    }

    func testAnOversizedOrSymlinkedIndexIsRejected() throws {
        let record = try begin()
        let folder = directory.appendingPathComponent("raiz/\(record.recoveryID.uuidString)")
        let indexURL = folder.appendingPathComponent("index.json")
        try Data(count: PixelArtRecoveryStore.maxIndexBytes + 1).write(to: indexURL)
        XCTAssertThrowsError(try store.readRecord(record.recoveryID)) { XCTAssertEqual(($0 as? PixelArtError)?.kind, .limit) }
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createSymbolicLink(at: indexURL, withDestinationURL: directory.appendingPathComponent("fuera.json"))
        XCTAssertThrowsError(try store.readRecord(record.recoveryID))
    }

    func testADamagedOrSubstitutedGenerationIsNeverOffered() throws {
        let record = try begin()
        try capture(record, generation: 1, duration: 160)
        try capture(record, generation: 2, duration: 161)
        let current = try store.readRecord(record.recoveryID)
        let newest = directory.appendingPathComponent("raiz/\(record.recoveryID.uuidString)/\(current.snapshots[0].fileName)")
        try Data("dañada".utf8).write(to: newest)
        XCTAssertEqual(store.validSnapshots(of: current).map(\.generation), [1])
        XCTAssertThrowsError(try store.load(current.snapshots[0], of: record.recoveryID))
        try FileManager.default.removeItem(at: newest)
        try FileManager.default.createSymbolicLink(at: newest, withDestinationURL: directory.appendingPathComponent("fuera.pxa"))
        XCTAssertEqual(store.validSnapshots(of: current).map(\.generation), [1], "un enlace simbólico no es una generación")
        XCTAssertThrowsError(try store.load(current.snapshots[0], of: record.recoveryID))
    }

    func testRecoveryFilesAreCreatedPrivately() throws {
        let record = try begin()
        try capture(record, generation: 1)
        let folder = directory.appendingPathComponent("raiz/\(record.recoveryID.uuidString)")
        func mode(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
            }
        XCTAssertEqual(try mode(directory.appendingPathComponent("raiz")), 0o700)
        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertEqual(try mode(folder.appendingPathComponent("index.json")), 0o600)
        let snapshotName = try XCTUnwrap(try store.readRecord(record.recoveryID).snapshots.first?.fileName)
        XCTAssertEqual(try mode(folder.appendingPathComponent(snapshotName)), 0o600)
    }

    func testTextInTheIndexIsBounded() throws {
        XCTAssertThrowsError(try store.begin(documentID: UUID(), suggestedName: String(repeating: "a", count: 5_000), originalURL: nil,
                                             context: .loosePixelArt, base: nil, owner: owner))
        XCTAssertThrowsError(try store.begin(documentID: UUID(), suggestedName: "a\u{0}b", originalURL: nil,
                                             context: .loosePixelArt, base: nil, owner: owner))
    }

    // MARK: Matriz de recuperación

    private func plan(_ record: PixelArtRecoveryRecord, _ original: PixelArtOriginalState) -> PixelArtRecoveryPlan {
        PixelArtRecoveryPlanner.plan(record: record, valid: store.validSnapshots(of: record), original: original)
    }

    func testEachRowOfTheRecoveryMatrix() throws {
        let record = try begin("bosque.pxa")
        try capture(record, generation: 1)
        let current = try store.readRecord(record.recoveryID)

        XCTAssertEqual(plan(current, .matchesBase).action, .recoverInPlace, "el original coincide con la base")
        XCTAssertEqual(plan(current, .changed).action, .recoverAsCopy(name: "bosque-recuperado.pxa", reason: .originalChanged))
        XCTAssertEqual(plan(current, .missing).action, .recoverAsCopy(name: "bosque-recuperado.pxa", reason: .originalMissing))
        XCTAssertEqual(plan(current, .alreadyOpen).action, .focusOpenSession, "no sustituye lo que está en memoria")

        let draft = try begin("Sin título.pxa", draft: true)
        try capture(draft, generation: 1)
        XCTAssertEqual(plan(try store.readRecord(draft.recoveryID), .notApplicable).action, .recoverDraft)

        let viewOnly = try begin("vista.pxa")
        try capture(viewOnly, generation: 1, changeClass: .viewOnly)
        XCTAssertEqual(plan(try store.readRecord(viewOnly.recoveryID), .matchesBase).action, .restoreViewOnly)

        let successor = UUID()
        let chained = try begin("cadena.pxa")
        try capture(chained, generation: 1)
        try store.claim(chained.recoveryID, newOwner: successor)
        try store.markSaved(chained.recoveryID, owner: successor, throughGeneration: 0,
                            newBase: PixelArtFileFingerprint(of: Data("x".utf8)))
        XCTAssertEqual(plan(try store.readRecord(chained.recoveryID), .matchesBase).action,
                       .recoverAsCopy(name: "cadena-recuperado.pxa", reason: .chainNotProven))
    }

    func testTheNewestGenerationDamagedFallsBackToTheOlderOneAndNothingValidIsNotAnEmptyCanvas() throws {
        let record = try begin()
        try capture(record, generation: 1, duration: 170)
        try capture(record, generation: 2, duration: 171)
        var current = try store.readRecord(record.recoveryID)
        let folder = directory.appendingPathComponent("raiz/\(record.recoveryID.uuidString)")
        try Data("dañada".utf8).write(to: folder.appendingPathComponent(current.snapshots[0].fileName))
        let fallback = plan(current, .matchesBase)
        XCTAssertEqual(fallback.snapshot?.generation, 1)
        XCTAssertTrue(fallback.fellBackToOlder, "la interfaz avisa de la generación y la fecha que ofrece")
        XCTAssertEqual(fallback.action, .recoverInPlace)

        try Data("dañada".utf8).write(to: folder.appendingPathComponent(current.snapshots[1].fileName))
        current = try store.readRecord(record.recoveryID)
        let none = plan(current, .matchesBase)
        XCTAssertEqual(none.action, .unrecoverable)
        XCTAssertNil(none.snapshot)
        XCTAssertEqual(try store.readRecord(record.recoveryID).snapshots.count, 2, "los candidatos se conservan")
    }

    func testTheSuggestedCopyNameNeverHasPathComponents() throws {
        let record = try store.begin(documentID: UUID(), suggestedName: "../../x/y.pxa", originalURL: nil, context: .loosePixelArt,
                                     base: nil, owner: owner)
        XCTAssertEqual(PixelArtRecoveryPlanner.copyName(for: record), "..-..-x-y-recuperado.pxa")
        let empty = try store.begin(documentID: UUID(), suggestedName: ".pxa", originalURL: nil, context: .loosePixelArt,
                                    base: nil, owner: owner)
        XCTAssertTrue(PixelArtRecoveryPlanner.copyName(for: empty).hasSuffix("-recuperado.pxa"))
        XCTAssertFalse(PixelArtRecoveryPlanner.copyName(for: empty).contains("/"))
    }
}
