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
        store.remember(url("/tmp/a.krabzik"))
        store.remember(url("/tmp/b.krabzik"))
        store.remember(url("/tmp/c.krabzik"))
        XCTAssertEqual(store.urls.map(\.lastPathComponent), ["c.krabzik", "b.krabzik", "a.krabzik"])

        // Reabrir uno lo mueve al frente, no lo duplica.
        store.remember(url("/tmp/a.krabzik"))
        XCTAssertEqual(store.urls.map(\.lastPathComponent), ["a.krabzik", "c.krabzik", "b.krabzik"])
        XCTAssertEqual(store.urls.count, 3)
    }

    func testStaysBoundedToTen() throws {
        let (defaults, _) = try defaults()
        let store = RecentProjectsStore(defaults: defaults)
        for index in 0 ..< 15 { store.remember(url("/tmp/p\(index).krabzik")) }
        XCTAssertEqual(store.urls.count, RecentProjectsStore.limit)
        XCTAssertEqual(store.urls.first?.lastPathComponent, "p14.krabzik")
        XCTAssertEqual(store.urls.last?.lastPathComponent, "p5.krabzik")
    }

    func testPathsAreNormalized() throws {
        let (defaults, _) = try defaults()
        let store = RecentProjectsStore(defaults: defaults)
        store.remember(url("/tmp/sub/../proyecto.krabzik"))
        XCTAssertEqual(store.urls, [url("/tmp/proyecto.krabzik")])

        // La misma ruta escrita de otra forma no agrega una entrada.
        store.remember(url("/tmp/./proyecto.krabzik"))
        XCTAssertEqual(store.urls.count, 1)
    }

    func testForgettingKeepsTheFileOnDisk() throws {
        let (defaults, _) = try defaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-recents-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Proyecto.krabzik")
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
        store.remember(url("/tmp/uno.krabzik"))
        store.remember(url("/tmp/dos.krabzik"))

        let reabierto = RecentProjectsStore(defaults: defaults)
        XCTAssertEqual(reabierto.urls.map(\.lastPathComponent), ["dos.krabzik", "uno.krabzik"])
    }

    func testStoredDuplicatesAreCollapsedOnLoad() throws {
        let (defaults, _) = try defaults()
        // Un historial guardado por una versión anterior, con repetidos y de más.
        let guardados = ["/tmp/a.krabzik", "/tmp/./a.krabzik", "/tmp/b.krabzik"]
            + (0 ..< 12).map { "/tmp/x\($0).krabzik" }
        defaults.set(guardados, forKey: "recentProjects")

        let store = RecentProjectsStore(defaults: defaults)
        XCTAssertEqual(store.urls.count, RecentProjectsStore.limit)
        XCTAssertEqual(store.urls.prefix(2).map(\.lastPathComponent), ["a.krabzik", "b.krabzik"])
    }
}
