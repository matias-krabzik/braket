import Foundation
@testable import Krabzik
import XCTest

@MainActor final class ProjectConnectionTests: XCTestCase {
    private func environment() throws -> (UserDefaults, WorkspaceSession, ConnectionStore) {
        let name = "ProjectConnections." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let session = WorkspaceSession(trustStore: TrustStore(defaults: defaults), errors: ErrorCenter())
        return (defaults, session, ConnectionStore(session: session, database: DatabaseController(), defaults: defaults))
    }
    private func open(_ session: WorkspaceSession, _ name: String) {
        session.open(Workspace(name: name), at: URL(fileURLWithPath: "/tmp/" + name + ".kzk"), trust: .trusted)
    }

    func testLegacyCatalogBecomesSharedWithoutAutomaticallyAttachingToProjects() async throws {
        let (defaults, session, _) = try environment()
        let legacy = DatabaseConnection(name: "Anterior")
        defaults.set(try JSONEncoder().encode([legacy]), forKey: ConnectionStore.profilesKey)
        let store = ConnectionStore(session: session, database: DatabaseController(), defaults: defaults)
        open(session, "Uno")
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(store.availableShared, [legacy])
        try store.addShared(legacy)
        XCTAssertEqual(store.profiles, [legacy])
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/legacy-script.sql"), data: Data("SELECT 1".utf8))
        store.select(legacy.id, for: document)
        store.remove(legacy)
        for _ in 0..<50 where !store.profiles.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try store.addShared(legacy)
        XCTAssertNil(store.selected(for: document), "Quitar y volver a agregar no restaura una selección descartada")
        open(session, "Dos")
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(store.availableShared, [legacy])
        let restored = ConnectionStore(session: session, database: DatabaseController(), defaults: defaults)
        open(session, "Uno")
        XCTAssertEqual(restored.profiles, [legacy])
        XCTAssertEqual(legacy.id, restored.profiles.first?.id)
    }

    func testNewProfilesArePrivateAndSharingRequiresExplicitAddition() async throws {
        let (_, session, store) = try environment()
        open(session, "Uno")
        let profile = DatabaseConnection(name: "Privada")
        defer { try? CredentialStore.remove(for: profile) }
        try await store.save(profile, password: "")
        XCTAssertFalse(store.isShared(profile))
        open(session, "Dos")
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(store.sharedProfiles.isEmpty)
        XCTAssertThrowsError(try store.addShared(profile))
        open(session, "Uno")
        try await store.save(profile, password: "", shared: true)
        open(session, "Dos")
        XCTAssertTrue(store.profiles.isEmpty)
        try store.addShared(profile)
        XCTAssertEqual(store.profiles, [profile])
        XCTAssertEqual(store.allProfiles.count, 1)
        do { try await store.save(profile, password: "", shared: false)
            XCTFail("No se convierte en privada una conexión usada por otro proyecto")
        } catch { XCTAssertTrue(store.isShared(profile)) }
    }

    func testRemovingSharedOnlyUnlinksThisProjectAndPreservesCredentials() async throws {
        let (_, session, store) = try environment()
        open(session, "Uno")
        let profile = DatabaseConnection(name: "Compartida")
        defer { try? CredentialStore.remove(for: profile) }
        try await store.save(profile, password: "Braket test ephemeral", shared: true)
        open(session, "Dos")
        try store.addShared(profile)
        store.remove(profile)
        for _ in 0..<50 where !store.profiles.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertEqual(store.sharedProfiles, [profile])
        XCTAssertEqual(try CredentialStore.read(for: profile), "Braket test ephemeral")
        open(session, "Uno")
        XCTAssertEqual(store.profiles, [profile])
    }

    func testSameFileSelectionsAndRecentsAreIndependentAcrossProjectsAndRelocation() async throws {
        let (_, session, store) = try environment()
        let first = DatabaseConnection(name: "Uno"), second = DatabaseConnection(name: "Dos")
        defer { try? CredentialStore.remove(for: first)
        try? CredentialStore.remove(for: second) }
        let document = try EditorDocument(url: URL(fileURLWithPath: "/tmp/shared-file.sql"), data: Data("SELECT 1".utf8))
        open(session, "Uno")
        try await store.save(first, password: "", shared: true)
        try await store.save(second, password: "", shared: true)
        store.select(first.id, for: document)
        open(session, "Dos")
        try store.addShared(first)
        try store.addShared(second)
        XCTAssertNil(store.selected(for: document))
        store.select(second.id, for: document)
        XCTAssertEqual(store.recentProfiles, [second])
        open(session, "Uno")
        XCTAssertEqual(store.selected(for: document), first)
        XCTAssertEqual(store.recentProfiles, [first])
        let from = URL(fileURLWithPath: "/tmp/Uno.kzk"), to = URL(fileURLWithPath: "/tmp/Renombrado.kzk")
        store.relocateProject(from: from, to: to)
        open(session, "Renombrado")
        XCTAssertEqual(store.selected(for: document), first)
        XCTAssertEqual(store.profiles.count, 2)
        XCTAssertEqual(store.recentProfiles, [first])
    }

    func testSharedPickerAddsFromActualWorkspaceUI() async throws {
        let qa = try QAHarness(self)
        let profile = try await qa.addConnection(QAFixtures.connection("Compartida de prueba"))
        let project = try qa.makeProject(name: "Proyecto")
        await qa.openProject(project)
        XCTAssertTrue(qa.controller.connections.profiles.isEmpty)
        await qa.mount()
        qa.controller.database.showingConnections = true
        await qa.assertScreen("connections")
        try await qa.tap("connections.shared")
        await qa.assertControl("connections.shared.add." + profile.name, title: "Agregar", enabled: true)
        try await qa.tap("connections.shared.add." + profile.name)
        await qa.assertControl("connections.shared.add." + profile.name, title: "Agregada", enabled: false)
        XCTAssertEqual(qa.controller.connections.profiles, [profile])
    }

    func testResultsCannotRefreshUsingAConnectionNotAddedToTheProject() async throws {
        let qa = try QAHarness(self)
        let profile = try await qa.addConnection(QAFixtures.connection("Anterior"))
        let project = try qa.makeProject(name: "Resultados")
        await qa.openProject(project)
        let document = try await qa.openScript("SELECT 1;", named: "consulta.sql")
        var result = SQLResult(statement: 1, line: 1)
        result.connection = profile
        result.sql = "SELECT 1"
        result.columns = ["id"]
        result.rows = [["1"]]
        result.rowCount = 1
        document.sqlExecution.receive(result)
        qa.controller.database.resultsVisible = true
        await qa.mount()
        await qa.assertControl("grid.refresh", enabled: false)
        try qa.controller.connections.addShared(profile)
        await qa.assertControl("grid.refresh", enabled: true)
    }

    func testCorruptNewCatalogNeverFallsBackToSharingPrivateProfiles() throws {
        let (defaults, session, _) = try environment()
        let old = DatabaseConnection(name: "Anterior")
        defaults.set(try JSONEncoder().encode([old]), forKey: ConnectionStore.profilesKey)
        defaults.set(Data("invalid".utf8), forKey: ConnectionStore.catalogKey)
        let store = ConnectionStore(session: session, database: DatabaseController(), defaults: defaults)
        XCTAssertTrue(store.sharedProfiles.isEmpty)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNotNil(session.errors.current)
    }
}
