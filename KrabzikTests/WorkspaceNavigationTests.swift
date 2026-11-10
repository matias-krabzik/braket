@testable import Krabzik
import XCTest

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    private func environment() throws -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-navigation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "krabzik-navigation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (directory, defaults)
    }

    private func project(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(name).krabzik")
        try Workspace(name: name).write(to: url)
        return url
    }

    // MARK: - Confianza (S1)

    /// Proyecto con un comando que deja rastro en disco, para comprobar que NO se ejecuta.
    private func hostileProject(in directory: URL, marker: URL) throws -> URL {
        let url = directory.appendingPathComponent("ajeno.krabzik")
        let project = CodeProject(name: "api", path: directory.path, kind: .files,
                                  command: "touch \(marker.path)")
        var workspace = Workspace(name: "ajeno")
        workspace.projects = [project]
        try workspace.write(to: url)
        return url
    }

    func testUntrustedWorkspaceCannotRunProcesses() async throws {
        let (directory, defaults) = try environment()
        let marker = directory.appendingPathComponent("rce-ocurrio")
        let url = try hostileProject(in: directory, marker: marker)
        let controller = WorkspaceController(defaults: defaults)
        var asked = 0
        controller.confirmTrust = { _ in
            asked += 1
            return .readOnly
        }
        controller.confirmCommand = { _ in
            XCTFail("no debe llegar a preguntar por el comando")
            return .cancel
        }
        await controller.openWorkspace(url)

        XCTAssertEqual(asked, 1, "abrir un proyecto nuevo tiene que preguntar")
        XCTAssertTrue(controller.isReadOnly)
        XCTAssertTrue(controller.runnableProjects.isEmpty, "en solo lectura no hay nada ejecutable")
        let project = try XCTUnwrap(controller.workspace?.projects.first)
        controller.toggleRun(project)
        controller.startAll()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "el comando del .krabzik no debe ejecutarse sin confianza")
        XCTAssertFalse(controller.runner.hasActiveProcesses)
    }

    func testCancellingTheTrustPromptDoesNotOpenTheProject() async throws {
        let (directory, defaults) = try environment()
        let url = try hostileProject(in: directory, marker: directory.appendingPathComponent("x"))
        let controller = WorkspaceController(defaults: defaults)
        controller.confirmTrust = { _ in .cancel }
        await controller.openWorkspace(url)
        XCTAssertNil(controller.workspace)
        XCTAssertNil(controller.workspaceURL)
    }

    func testTrustSurvivesRelaunchAndCommandEditRevokesApproval() async throws {
        let (directory, defaults) = try environment()
        let marker = directory.appendingPathComponent("no-importa")
        let url = try hostileProject(in: directory, marker: marker)

        let first = WorkspaceController(defaults: defaults)
        first.confirmTrust = { _ in .trust }
        var commandAsks = 0
        first.confirmCommand = { _ in
            commandAsks += 1
            return .always
        }
        await first.openWorkspace(url)
        XCTAssertFalse(first.isReadOnly)
        let project = try XCTUnwrap(first.workspace?.projects.first)
        XCTAssertTrue(first.trust.isApproved(command: project.command, project: project.id, workspaceURL: url) == false,
                      "todavía no se aprobó el comando")
        first.toggleRun(project)
        XCTAssertEqual(commandAsks, 1)
        XCTAssertTrue(first.trust.isApproved(command: project.command, project: project.id, workspaceURL: url))
        first.runner.terminateImmediately()

        // Otra instancia con los mismos defaults: ni confianza ni comando se vuelven a pedir.
        let second = WorkspaceController(defaults: defaults)
        second.confirmTrust = { _ in
            XCTFail("la confianza tiene que persistir")
            return .cancel
        }
        second.confirmCommand = { _ in
            XCTFail("la aprobación del comando tiene que persistir")
            return .cancel
        }
        await second.openWorkspace(url)
        XCTAssertFalse(second.isReadOnly)
        let same = try XCTUnwrap(second.workspace?.projects.first)
        XCTAssertTrue(second.trust.isApproved(command: same.command, project: same.id, workspaceURL: url))

        // Editar el comando revoca la aprobación: se guarda por hash del comando.
        var edited = same
        edited.command = "touch \(marker.path)-otro"
        XCTAssertFalse(second.trust.isApproved(command: edited.command, project: edited.id, workspaceURL: url))
    }

    func testExternalRootsAreNotMountedUntilTrusted() async throws {
        let (directory, defaults) = try environment()
        let outside = directory.appendingPathComponent("afuera")
        let inside = directory.appendingPathComponent("adentro/sub")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let home = directory.appendingPathComponent("adentro")
        let url = home.appendingPathComponent("p.krabzik")
        var workspace = Workspace(name: "p")
        workspace.projects = [
            CodeProject(name: "interno", path: "sub", kind: .files, command: ""),
            CodeProject(name: "externo", path: outside.path, kind: .files, command: ""),
        ]
        try workspace.write(to: url)

        let controller = WorkspaceController(defaults: defaults)
        controller.confirmTrust = { prompt in
            XCTAssertEqual(prompt.externalFolders.count, 1, "la hoja tiene que listar la carpeta externa")
            return .readOnly
        }
        await controller.openWorkspace(url)
        XCTAssertEqual(controller.mountedProjects.map(\.name), ["interno"])
        controller.trustCurrentWorkspace()
        XCTAssertEqual(controller.mountedProjects.map(\.name), ["interno", "externo"])
    }

    func testAgentScopeRejectsUntrustedExternalRoots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("krabzik-s1-\(UUID())")
        let outside = directory.appendingPathComponent("afuera")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("home/p.krabzik")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var workspace = Workspace(name: "p")
        workspace.projects = [CodeProject(name: "externo", path: outside.path, kind: .files, command: "")]
        try workspace.write(to: url)

        // Confiado: la raíz externa entra en writableRoots.
        let trusted = try AgentScope.make(workspace: workspace, url: url, projectID: nil)
        XCTAssertEqual(trusted.roots.count, 1)
        // Sin confiar: no queda ninguna raíz, así que lanza en vez de dar escritura.
        XCTAssertThrowsError(try AgentScope.make(workspace: workspace, url: url,
                                                 projectID: nil, allowExternal: false))
    }

    func testFreshlyCreatedWorkspaceNeedsNoConfirmation() async throws {
        let (directory, defaults) = try environment()
        let url = try project("propio", in: directory)
        let controller = WorkspaceController(defaults: defaults)
        controller.trust.markTrusted(url)   // es lo que hace createWorkspace
        controller.confirmTrust = { _ in
            XCTFail("un proyecto propio no debe preguntar")
            return .cancel
        }
        await controller.openWorkspace(url)
        XCTAssertFalse(controller.isReadOnly)
    }

    func testLegacyRecentProjectsAreMigratedAsTrusted() async throws {
        let (directory, defaults) = try environment()
        let url = try project("viejo", in: directory)
        // Estado previo a S1: el proyecto estaba en recientes y nadie sabía de confianza.
        defaults.set([url.path], forKey: "recentProjects")
        let controller = WorkspaceController(defaults: defaults)
        controller.confirmTrust = { _ in
            XCTFail("lo que ya se usaba no debe preguntar")
            return .cancel
        }
        await controller.openWorkspace(url)
        XCTAssertFalse(controller.isReadOnly)
    }

    func testNormalLaunchShowsHomeEvenWithRecentProject() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Reciente", in: directory)
        defaults.set([url.path], forKey: "recentProjects")
        let controller = WorkspaceController(defaults: defaults)

        await controller.start(arguments: ["Krabzik"])

        XCTAssertNil(controller.workspace)
        XCTAssertNil(controller.workspaceURL)
        XCTAssertEqual(controller.recentProjects, [url])
        XCTAssertTrue(controller.documents.isEmpty)
        XCTAssertFalse(controller.runner.hasActiveProcesses)
    }

    func testExplicitLaunchOpensRequestedProjectOnlyOnce() async throws {
        let (directory, defaults) = try environment()
        let first = try project("Primero", in: directory)
        let second = try project("Segundo", in: directory)
        defaults.set([first.path], forKey: "recentProjects")
        let controller = WorkspaceController(defaults: defaults)
        controller.confirmTrust = { _ in .trust }

        await controller.start(arguments: ["Krabzik", "--workspace", second.path])
        XCTAssertEqual(controller.workspace?.name, "Segundo")
        XCTAssertEqual(controller.recentProjects, [second, first])
        await controller.start(arguments: ["Krabzik", "--workspace", first.path])
        XCTAssertEqual(controller.workspaceURL, second)
    }

    func testRecentProjectsPersistInOpeningOrderWithoutDuplicatesAndStayBounded() async throws {
        let (directory, defaults) = try environment()
        let urls = try (0..<12).map { try project("Proyecto \($0)", in: directory) }
        let controller = WorkspaceController(defaults: defaults)
        controller.confirmTrust = { _ in .trust }
        for url in urls { await controller.openWorkspace(url) }
        XCTAssertEqual(controller.recentProjects, Array(urls.reversed().prefix(10)))

        await controller.openWorkspace(urls[5])
        let expected = [urls[5]] + urls.reversed().filter { $0 != urls[5] && $0 != urls[0] && $0 != urls[1] }
        XCTAssertEqual(controller.recentProjects, expected)
        XCTAssertEqual(WorkspaceController(defaults: defaults).recentProjects, expected)
    }

    func testRemovingRecentDoesNotDeleteOrCloseProject() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Conservar", in: directory)
        let controller = WorkspaceController(defaults: defaults)
        controller.confirmTrust = { _ in .trust }
        await controller.openWorkspace(url)

        controller.removeRecentProject(url)

        XCTAssertTrue(controller.recentProjects.isEmpty)
        XCTAssertTrue(WorkspaceController(defaults: defaults).recentProjects.isEmpty)
        XCTAssertEqual(controller.workspaceURL, url)
        XCTAssertEqual(try Workspace.read(from: url).name, "Conservar")
    }

    func testReturningHomeClearsEditorAndDatabaseSelectionButKeepsHistory() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Proyecto", in: directory)
        let controller = WorkspaceController(defaults: defaults)
        controller.confirmTrust = { _ in .trust }
        await controller.openWorkspace(url)
        // Se abre de verdad por el store: el controlador ya no deja inyectar documentos.
        let archivo = directory.appendingPathComponent("test.sql")
        try Data("SELECT 1;".utf8).write(to: archivo)
        try await controller.docs.open(archivo)
        XCTAssertEqual(controller.documents.count, 1)
        controller.selectedProjectID = UUID()
        controller.database.install([DatabaseConnection()])

        await controller.closeWorkspace()

        XCTAssertNil(controller.workspace)
        XCTAssertNil(controller.workspaceURL)
        XCTAssertTrue(controller.documents.isEmpty)
        XCTAssertNil(controller.selectedDocumentID)
        XCTAssertNil(controller.selectedProjectID)
        XCTAssertNil(controller.database.selectedConnectionID)
        XCTAssertTrue(controller.database.states.isEmpty)
        XCTAssertFalse(controller.isSwitchingWorkspace)
        XCTAssertEqual(controller.recentProjects, [url])
        await controller.openWorkspace(url)
        XCTAssertEqual(controller.workspaceURL, url)
    }

    func testMissingRecentReportsErrorAndPreservesCurrentProject() async throws {
        let (directory, defaults) = try environment()
        let url = try project("Disponible", in: directory)
        let missing = directory.appendingPathComponent("Movido.krabzik")
        defaults.set([missing.path], forKey: "recentProjects")
        let controller = WorkspaceController(defaults: defaults)
        controller.confirmTrust = { _ in .trust }

        await controller.openWorkspace(missing)
        XCTAssertNil(controller.workspace)
        XCTAssertNotNil(controller.errors.current)
        XCTAssertEqual(controller.recentProjects, [missing])
        XCTAssertFalse(controller.isSwitchingWorkspace)

        await controller.openWorkspace(url)
        controller.errors.dismissAll()
        await controller.openWorkspace(missing)
        XCTAssertEqual(controller.workspaceURL, url)
        XCTAssertNotNil(controller.errors.current)
        XCTAssertEqual(controller.recentProjects, [url, missing])
    }
}
