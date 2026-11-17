@testable import Krabzik
import XCTest

/// Suite INI del catálogo: lo primero que ve el usuario.
///
/// Cada escenario monta la interfaz de verdad y usa los controles por su identificador,
/// así que afirma lo que la pantalla ofrece y no lo que el controlador podría hacer.
@MainActor
final class QAStartupTests: XCTestCase {
    /// INI-01, INI-02
    func testWelcomeOffersItsActionsWithNoProject() async throws {
        let qa = try QAHarness(self)
        await qa.mount()
        await qa.assertScreen("welcome")
        await qa.assertControl("welcome.open", title: "Abrir proyecto…", enabled: true)
        await qa.assertControl("welcome.create", title: "Crear proyecto…", enabled: true)
        await qa.assertControl("welcome.pixel.new", title: "Nueva imagen pixel art", enabled: true)
        await qa.assertControl("welcome.pixel.open", title: "Abrir imagen pixel art…", enabled: true)
        XCTAssertNil(qa.controller.workspace)
        XCTAssertTrue(qa.controller.recentProjects.isEmpty)
        qa.assertNoControl("welcome.recent.open.0")
    }

    /// INI-03, ABR-07
    func testOpeningAProjectAddsItToRecentsAndClosingReturnsHome() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.mount()
        await qa.openProject(url)
        await qa.assertScreen("welcome", present: false)
        XCTAssertEqual(qa.controller.recentProjects.first?.standardizedFileURL, url.standardizedFileURL)

        qa.controller.requestCloseWorkspace()
        await qa.assertEvent("project.close.request")
        await qa.controller.closeWorkspace()
        await qa.assertEvent("project.close.ok")
        await qa.settle(until: { qa.controller.workspace == nil })
        await qa.assertScreen("welcome")
        await qa.assertControl("welcome.recent.open.0", title: "Tienda")
    }

    /// INI-04
    func testForgettingARecentKeepsTheFileOnDisk() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        await qa.controller.closeWorkspace()
        await qa.mount()
        await qa.assertControl("welcome.recent.forget.0", title: "Quitar de recientes", enabled: true)
        try await qa.tap("welcome.recent.forget.0")
        await qa.settle(until: { qa.controller.recentProjects.isEmpty })
        XCTAssertTrue(qa.controller.recentProjects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "el .kzk tiene que seguir en disco")
    }

    /// INI-05
    func testOpeningFromRecentsOpensThatProject() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        qa.controller.recents.remember(url)
        await qa.mount()
        await qa.assertControl("welcome.recent.open.0", title: "Tienda", enabled: true)
        try await qa.tap("welcome.recent.open.0")
        await qa.settle(until: { qa.controller.workspaceURL != nil })
        await qa.assertEvent("project.open.ok", ["name": "Tienda"])
        XCTAssertEqual(qa.controller.workspaceURL?.standardizedFileURL, url.standardizedFileURL)
    }

    /// INI-06
    func testCancellingTheOpenDialogChangesNothing() async throws {
        let qa = try QAHarness(self)
        qa.script.chooseWorkspace = nil
        await qa.mount()
        try await qa.tap("welcome.open")
        await qa.assertEvent("dialog.file.chooseWorkspace", ["answer": "cancel"])
        qa.assertNoEvent("project.open.request")
        XCTAssertNil(qa.controller.workspace)
    }

    /// INI-07
    func testSwitchingBlocksASecondRequest() async throws {
        let qa = try QAHarness(self)
        XCTAssertTrue(qa.controller.session.beginSwitch())
        qa.controller.createWorkspace()
        await qa.assertEvent("wizard.open.request", ["switching": "true"])
        XCTAssertFalse(qa.controller.showingProjectWizard, "con una transición en curso no se abre el asistente")
        qa.controller.session.endSwitch()
    }

    /// INI-08
    func testTheLastSessionComesBackOnTheNextLaunch() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda", folders: ["app"])
        await qa.openProject(url)
        let file = url.deletingLastPathComponent().appendingPathComponent("app/notas.txt")
        try Data("hola".utf8).write(to: file)
        qa.controller.files.open(file)
        await qa.settle(until: { qa.controller.documents.contains { $0.url.lastPathComponent == "notas.txt" } })
        qa.controller.saveSessionState(qa.controller.captureSessionState())
        XCTAssertNotNil(qa.controller.restoration.load(), "la sesión tiene que quedar guardada")

        let next = qa.relaunch()
        await next.start(arguments: ["Braket"])
        await qa.assertEvent("app.start", ["restoring": "true"])
        await qa.settle(until: { next.workspaceURL != nil }, timeout: 5)
        XCTAssertEqual(next.workspaceURL?.standardizedFileURL, url.standardizedFileURL)
        let restored = await qa.settle(until: {
            next.documents.contains { $0.url.lastPathComponent == "notas.txt" }
        }, timeout: 5)
        XCTAssertTrue(restored, "la pestaña que estaba abierta tiene que volver\n" + qa.timelineText())
    }

    /// INI-10
    func testAPixelArtFileFromFinderOpensTheImageAndNoProject() async throws {
        let qa = try QAHarness(self)
        let url = qa.root.appendingPathComponent("bosque.pxa")
        _ = try await qa.controller.docs.createPixelArt(at: url, width: 8, height: 8)
        qa.controller.docs.closeAll()
        XCTAssertTrue(qa.controller.documents.isEmpty)

        qa.controller.requestWorkspace(url)
        await qa.settle(until: { !qa.controller.documents.isEmpty }, timeout: 3)
        let document = try XCTUnwrap(qa.controller.documents.first)
        XCTAssertNotNil(document.pixelArt, "un .pxa se abre como imagen")
        XCTAssertEqual(document.url.lastPathComponent, "bosque.pxa")
        XCTAssertNil(qa.controller.workspace, "abrir una imagen no abre ningún proyecto")
        await qa.controller.start(arguments: ["Braket"])
        XCTAssertNil(qa.controller.workspace, "la imagen pedida desde Finder gana sobre la sesión guardada")
    }

    /// INI-09
    func testLaunchArgumentOpensThatProject() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "DesdeLaTerminal")
        await qa.controller.start(arguments: ["Braket", "--workspace", url.path])
        await qa.assertEvent("app.start")
        await qa.assertEvent("project.open.ok", ["name": "DesdeLaTerminal"])
        XCTAssertEqual(qa.controller.workspaceURL?.standardizedFileURL, url.standardizedFileURL)
    }
}
