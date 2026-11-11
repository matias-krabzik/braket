@testable import Krabzik
import XCTest

/// El historial de proyectos: orden, repetidos, límite, normalización y persistencia.
/// Antes estaba repartido entre el `init`, `install` y `removeRecentProject` del
/// controlador, y solo se probaba de rebote. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor
final class RecentProjectsTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "krabzik-recents-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testOrderIsByLastOpening() throws {
        let (defaults, _) = try defaults()
        let store = RecentProjectsStore(defaults: defaults)
        store.remember(url("/tmp/a.kzk"))
        store.remember(url("/tmp/b.kzk"))
        store.remember(url("/tmp/c.kzk"))
        XCTAssertEqual(store.urls.map(\.lastPathComponent), ["c.kzk", "b.kzk", "a.kzk"])

        // Reabrir uno lo mueve al frente, no lo duplica.
        store.remember(url("/tmp/a.kzk"))
        XCTAssertEqual(store.urls.map(\.lastPathComponent), ["a.kzk", "c.kzk", "b.kzk"])
        XCTAssertEqual(store.urls.count, 3)
    }

    func testStaysBoundedToTen() throws {
        let (defaults, _) = try defaults()
        let store = RecentProjectsStore(defaults: defaults)
        for index in 0 ..< 15 { store.remember(url("/tmp/p\(index).kzk")) }
        XCTAssertEqual(store.urls.count, RecentProjectsStore.limit)
        XCTAssertEqual(store.urls.first?.lastPathComponent, "p14.kzk")
        XCTAssertEqual(store.urls.last?.lastPathComponent, "p5.kzk")
    }

    func testPathsAreNormalized() throws {
        let (defaults, _) = try defaults()
        let store = RecentProjectsStore(defaults: defaults)
        store.remember(url("/tmp/sub/../proyecto.kzk"))
        XCTAssertEqual(store.urls, [url("/tmp/proyecto.kzk")])

        // La misma ruta escrita de otra forma no agrega una entrada.
        store.remember(url("/tmp/./proyecto.kzk"))
        XCTAssertEqual(store.urls.count, 1)
    }

    func testForgettingKeepsTheFileOnDisk() throws {
        let (defaults, _) = try defaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-recents-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Proyecto.kzk")
        try Workspace(name: "Proyecto").write(to: project)

        let store = RecentProjectsStore(defaults: defaults)
        store.remember(project)
        store.forget(project)

        XCTAssertTrue(store.urls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path),
                      "quitar del historial no borra el proyecto")
    }

    func testSurvivesRelaunch() throws {
        let (defaults, _) = try defaults()
        let store = RecentProjectsStore(defaults: defaults)
        store.remember(url("/tmp/uno.kzk"))
        store.remember(url("/tmp/dos.kzk"))

        let reabierto = RecentProjectsStore(defaults: defaults)
        XCTAssertEqual(reabierto.urls.map(\.lastPathComponent), ["dos.kzk", "uno.kzk"])
    }

    func testStoredDuplicatesAreCollapsedOnLoad() throws {
        let (defaults, _) = try defaults()
        // Un historial guardado por una versión anterior, con repetidos y de más.
        let guardados = ["/tmp/a.kzk", "/tmp/./a.kzk", "/tmp/b.kzk"]
            + (0 ..< 12).map { "/tmp/x\($0).kzk" }
        defaults.set(guardados, forKey: "recentProjects")

        let store = RecentProjectsStore(defaults: defaults)
        XCTAssertEqual(store.urls.count, RecentProjectsStore.limit)
        XCTAssertEqual(store.urls.prefix(2).map(\.lastPathComponent), ["a.kzk", "b.kzk"])
    }
}
