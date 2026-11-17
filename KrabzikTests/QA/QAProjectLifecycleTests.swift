@testable import Krabzik
import XCTest

/// Suite ABR del catálogo: abrir, cerrar y cambiar de proyecto, con la confianza en el
/// medio. Lo que no se puede perder: abrir un proyecto no ejecuta nada.
@MainActor
final class QAProjectLifecycleTests: XCTestCase {
    /// ABR-01
    func testAnUnknownProjectAsksForTrustBeforeTouchingTheOpenOne() async throws {
        let qa = try QAHarness(self)
        let known = try qa.makeProject(name: "Conocido")
        let unknown = try qa.makeProject(name: "Desconocido", trusted: false)
        await qa.openProject(known)
        qa.script.trust = .trust
        await qa.controller.openWorkspace(unknown)
        await qa.assertEvent("dialog.project.trust", ["answer": "trust", "project": "Desconocido"])
        qa.assertOrder("dialog.project.trust", before: "project.prepareToLeave.begin")
        XCTAssertEqual(qa.controller.workspaceURL?.standardizedFileURL, unknown.standardizedFileURL)
    }

    /// ABR-02, PRO-04
    func testReadOnlyTrustDisablesEverythingThatWrites() async throws {
        let qa = try QAHarness(self)
        // La carpeta tiene que quedar FUERA de la del proyecto para que cuente como externa.
        let home = qa.root.appendingPathComponent("Proyecto", isDirectory: true)
        let folder = qa.root.appendingPathComponent("Externo", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var workspace = Workspace(name: "Ajeno", projects: [CodeProject(name: "api", path: folder.path,
                                                                        kind: .files, command: "npm start")])
        workspace.connections = []
        let url = home.appendingPathComponent("Ajeno").appendingPathExtension(Workspace.fileExtension)
        try JSONEncoder().encode(workspace).write(to: url)
        qa.script.trust = .readOnly
        await qa.mount()
        await qa.openProject(url)
        await qa.assertEvent("dialog.project.trust", ["answer": "readOnly"])
        await qa.assertEvent("project.open.ok", ["readOnly": "true"])
        XCTAssertTrue(qa.controller.isReadOnly)
        XCTAssertTrue(qa.controller.runnableProjects.isEmpty, "en solo lectura no hay nada que ejecutar")
        XCTAssertTrue(qa.controller.mountedProjects.isEmpty, "las carpetas externas no se montan")
        qa.controller.files.create()
        qa.assertNoEvent("file.create")
        XCTAssertFalse(qa.controller.runner.hasActiveProcesses)
    }

    /// ABR-03
    func testCancellingTrustKeepsTheCurrentProject() async throws {
        let qa = try QAHarness(self)
        let known = try qa.makeProject(name: "Conocido")
        let unknown = try qa.makeProject(name: "Desconocido", trusted: false)
        await qa.openProject(known)
        qa.script.trust = .cancel
        await qa.controller.openWorkspace(unknown)
        await qa.assertEvent("dialog.project.trust", ["answer": "cancel"])
        await qa.assertEvent("project.open.cancelled", ["stage": "trust"])
        XCTAssertEqual(qa.controller.workspaceURL?.standardizedFileURL, known.standardizedFileURL,
                       "el proyecto que estaba abierto no se toca")
    }

    /// ABR-04
    func testAKnownProjectDoesNotAskAgain() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda", trusted: false)
        qa.script.trust = .trust
        await qa.openProject(url)
        await qa.assertEvent("dialog.project.trust")
        await qa.controller.closeWorkspace()
        QAProbe.reset()
        await qa.openProject(url)
        qa.assertNoEvent("dialog.project.trust")
        XCTAssertFalse(qa.controller.isReadOnly)
    }

    /// ABR-06
    func testOpeningTheSameProjectTwiceIsIgnored() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        await qa.controller.openWorkspace(url)
        await qa.assertEvent("project.open.ignored")
        XCTAssertEqual(qa.controller.openWorkspaceURLs.count, 1)
    }

    /// ABR-11
    func testClosingOneOfTwoOpenProjectsMovesToTheOther() async throws {
        let qa = try QAHarness(self)
        let first = try qa.makeProject(name: "Uno")
        let second = try qa.makeProject(name: "Dos")
        await qa.openProject(first)
        await qa.openProject(second)
        XCTAssertEqual(qa.controller.openWorkspaceURLs.count, 2)
        await qa.controller.closeWorkspace(second)
        await qa.settle(until: { qa.controller.workspaceURL?.standardizedFileURL == first.standardizedFileURL })
        XCTAssertEqual(qa.controller.workspaceURL?.standardizedFileURL, first.standardizedFileURL)
        XCTAssertEqual(qa.controller.openWorkspaceURLs.count, 1)
        XCTAssertNotNil(qa.controller.workspace, "no vuelve al inicio mientras quede otro proyecto")
    }

    /// ABR-12
    func testReorderingTheOpenProjectsInTheRail() async throws {
        let qa = try QAHarness(self)
        let first = try qa.makeProject(name: "Uno")
        let second = try qa.makeProject(name: "Dos")
        let third = try qa.makeProject(name: "Tres")
        for url in [first, second, third] { await qa.openProject(url) }
        XCTAssertEqual(qa.controller.openWorkspaceURLs.map { $0.deletingPathExtension().lastPathComponent },
                       ["Uno", "Dos", "Tres"])

        qa.controller.moveOpenWorkspace(third, to: first)
        await qa.assertEvent("state.rail", ["order": "Tres,Uno,Dos"])
        XCTAssertEqual(qa.controller.openWorkspaceURLs.map { $0.deletingPathExtension().lastPathComponent },
                       ["Tres", "Uno", "Dos"])

        // El orden es lo que se guarda para la próxima corrida.
        let state = try XCTUnwrap(qa.controller.captureSessionState())
        XCTAssertEqual(state.openWorkspaceStates?.map { $0.workspaceURL.deletingPathExtension().lastPathComponent },
                       ["Tres", "Uno", "Dos"])
    }

    /// ABR-13
    func testMovingTheProjectFileUpdatesRecentsAndTheSession() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda", folders: ["app"])
        await qa.openProject(url)
        XCTAssertEqual(qa.controller.recentProjects.first?.standardizedFileURL, url.standardizedFileURL)

        let destination = qa.root.appendingPathComponent("Movido/Tienda.kzk")
        let moved = await qa.controller.relocateWorkspace(to: destination, createDirectory: true)
        XCTAssertTrue(moved, qa.timelineText())
        await qa.assertEvent("project.relocate.ok")
        XCTAssertEqual(qa.controller.workspaceURL?.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "el .kzk viejo ya no está")

        let recents = qa.controller.recentProjects.map(\.standardizedFileURL)
        XCTAssertTrue(recents.contains(destination.standardizedFileURL), "la ruta nueva entra en recientes")
        XCTAssertFalse(recents.contains(url.standardizedFileURL), "y la vieja sale")
        let state = try XCTUnwrap(qa.controller.captureSessionState())
        XCTAssertEqual(state.workspaceURL.standardizedFileURL, destination.standardizedFileURL)
    }
}
