@testable import Krabzik
import XCTest

/// Suite CFG del catálogo: configuración, ventana y lo que la interfaz conserva.
///
/// Las preferencias del arnés están aisladas (`UserDefaults(suiteName:)`) y la interfaz
/// mira `Theme.settings`, que el arnés apunta a esa instancia: un escenario puede cambiar
/// el tema o el zoom sin tocar las preferencias reales, que son las del host de pruebas.
///
/// El zoom y los paneles se usan **por las órdenes del menú** (`menu.view.*`), que es
/// como los usa la persona, así que la habilitación en los topes también queda afirmada.
@MainActor
final class QASettingsTests: XCTestCase {
    /// CFG-01
    func testTheThemeAppliesToTheWindowAndIsRemembered() async throws {
        let qa = try QAHarness(self)
        await qa.mount()
        XCTAssertEqual(qa.controller.settings.theme, .graphite, "el tema de fábrica")
        XCTAssertEqual(Theme.colorScheme, .dark)

        qa.controller.settings.theme = .light
        await qa.settle(timeout: 0.2)
        XCTAssertEqual(Theme.colorScheme, .light, "la ventana pasa a apariencia clara")
        XCTAssertEqual(Theme.surfaceInk, .black)

        qa.controller.settings.theme = .midnight
        await qa.settle(timeout: 0.2)
        XCTAssertEqual(Theme.colorScheme, .dark)
        XCTAssertEqual(AppSettings(defaults: qa.defaults).theme, .midnight,
                       "el tema elegido se conserva para la próxima corrida")
    }

    /// CFG-02
    func testZoomStopsAtBothEndsAndCanBeReset() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Zoom")
        await qa.openProject(url)
        await qa.mount()
        await qa.assertControl("menu.view.zoomReset", title: "Restablecer zoom", enabled: false)

        for _ in 0..<10 where qa.controller.settings.uiScale < AppSettings.uiScaleRange.upperBound {
            try await qa.tap("menu.view.zoomIn")
        }
        XCTAssertEqual(qa.controller.settings.uiScale, AppSettings.uiScaleRange.upperBound, accuracy: 0.001)
        await qa.assertControl("menu.view.zoomIn", title: "Aumentar zoom", enabled: false)
        await qa.assertControl("menu.view.zoomOut", enabled: true)
        await qa.assertEvent("state.zoom", ["scale": "1.5"])

        for _ in 0..<12 where qa.controller.settings.uiScale > AppSettings.uiScaleRange.lowerBound {
            try await qa.tap("menu.view.zoomOut")
        }
        XCTAssertEqual(qa.controller.settings.uiScale, AppSettings.uiScaleRange.lowerBound, accuracy: 0.001)
        await qa.assertControl("menu.view.zoomOut", title: "Reducir zoom", enabled: false)

        try await qa.tap("menu.view.zoomReset")
        XCTAssertEqual(qa.controller.settings.uiScale, 1, accuracy: 0.001)
        await qa.assertControl("menu.view.zoomReset", enabled: false)
        XCTAssertEqual(Theme.zoom(10), 10, accuracy: 0.001)
    }

    /// CFG-03
    func testProcessManagerRemainsVisibleAcrossDocumentKinds() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Paneles", folders: ["app"])
        await qa.openProject(url)
        await qa.mount()
        XCTAssertTrue(qa.controller.sidebarVisible)

        try await qa.tap("menu.view.sidebar")
        await qa.assertEvent("state.sidebar", ["visible": "false"])
        XCTAssertFalse(qa.controller.sidebarVisible)
        await qa.assertScreen("explorer.files", present: false)
        try await qa.tap("menu.view.sidebar")
        XCTAssertTrue(qa.controller.sidebarVisible)
        await qa.assertScreen("explorer.files")

        // El administrador conserva su visibilidad al cambiar de tipo de documento.
        let text = url.deletingLastPathComponent().appendingPathComponent("app/notas.txt")
        try Data("hola".utf8).write(to: text)
        qa.controller.files.open(text)
        await qa.settle(until: { qa.controller.selectedDocument?.url.lastPathComponent == "notas.txt" })
        try await qa.tap("menu.view.processes")
        await qa.assertEvent("state.processesPanel", ["visible": "true", "pixel": "false"])
        XCTAssertTrue(qa.controller.processesVisible)

        let image = url.deletingLastPathComponent().appendingPathComponent("app/dibujo.pxa")
        _ = try await qa.controller.docs.createPixelArt(at: image, width: 8, height: 8)
        await qa.settle(until: { qa.controller.selectedDocument?.pixelArt != nil })
        XCTAssertTrue(qa.controller.selectedProcessesVisible, "el administrador sigue abierto")
        try await qa.tap("menu.view.processes")
        await qa.assertEvent("state.processesPanel", ["visible": "false", "pixel": "true"])
        XCTAssertFalse(qa.controller.pixelProcessesVisible)
        XCTAssertFalse(qa.controller.processesVisible, "lo de la pestaña de código quedó como estaba")
    }

    /// CFG-04
    func testTurningOffSessionRestoreStartsAtHome() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        qa.controller.saveSessionState(qa.controller.captureSessionState())
        XCTAssertNotNil(qa.controller.restoration.load())

        qa.controller.settings.restoreLastState = false
        XCTAssertNil(qa.controller.restoration.load(), "apagar la opción borra la sesión guardada")

        let next = qa.relaunch()
        await next.start(arguments: ["Braket"])
        await qa.assertEvent("app.start", ["restoring": "false"])
        XCTAssertNil(next.workspace, "arranca sin proyecto")
        await qa.mount(next)
        await qa.assertScreen("welcome")
        await qa.assertControl("welcome.recent.open.0", title: "Tienda", enabled: true)
    }
}
