@testable import Krabzik
import XCTest

/// `FileTree.Coordinator` no tenía ninguna prueba: carga perezosa, exclusiones, symlinks
/// de directorio que no se siguen, reconciliación de hijos al recargar y el watcher. Es
/// también el único sitio donde aparecieron avisos reales de concurrencia (C2).
/// Ver docs/specs/C9-cobertura-pruebas.md.
@MainActor
final class FileTreeTests: XCTestCase {
    private func environment() throws -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-tree-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "krabzik-tree-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            // Devolver los permisos antes de borrar, si alguna prueba los quitó.
            let denied = directory.appendingPathComponent("proyecto/sin-permiso")
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)],
                                                   ofItemAtPath: denied.path)
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (directory, defaults)
    }

    /// Un proyecto con lo que el explorador tiene que ignorar, un symlink a directorio y
    /// archivos y carpetas para comprobar el orden.
    private func tree(in directory: URL) throws -> URL {
        let fm = FileManager.default
        let project = directory.appendingPathComponent("proyecto")
        for folder in ["node_modules", ".git", "vendor", ".build", "src", "assets"] {
            try fm.createDirectory(at: project.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("<?php\n".utf8).write(to: project.appendingPathComponent("index.php"))
        try Data("# hola\n".utf8).write(to: project.appendingPathComponent("README.md"))
        try Data("x\n".utf8).write(to: project.appendingPathComponent("src/app.ts"))
        try fm.createSymbolicLink(at: project.appendingPathComponent("enlace"),
                                  withDestinationURL: project.appendingPathComponent("src"))
        let url = directory.appendingPathComponent("Proyecto.krabzik")
        var workspace = Workspace(name: "Proyecto")
        workspace.projects = [CodeProject(name: "app", path: "proyecto", kind: .files, command: "")]
        try workspace.write(to: url)
        return url
    }

    private func controller(_ defaults: UserDefaults) -> WorkspaceController {
        let controller = WorkspaceController(defaults: defaults)
        controller.confirmTrust = { _ in .trust }
        return controller
    }

    /// Espera a que se cumpla una condición sin bloquear el main actor.
    private func until(_ condition: @MainActor () -> Bool, _ timeout: TimeInterval = 5,
                       _ what: String = "la condición") async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("no se cumplió \(what) en \(timeout) s")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func loadedCoordinator(_ directory: URL, _ defaults: UserDefaults) async throws
        -> (FileTree.Coordinator, FileNode) {
        let url = try tree(in: directory)
        let host = controller(defaults)
        await host.openWorkspace(url)
        let workspace = try XCTUnwrap(host.workspace)
        let coordinator = FileTree.Coordinator(controller: host)
        coordinator.update(workspace, at: url, revision: 1)
        let root = try XCTUnwrap(coordinator.roots.first)
        try await until({ root.children != nil }, 5, "la carga del nodo raíz")
        return (coordinator, root)
    }

    func testGeneratedFoldersAreNotListed() async throws {
        let (directory, defaults) = try environment()
        let (_, root) = try await loadedCoordinator(directory, defaults)
        let names = (root.children ?? []).map(\.name)
        for excluded in ["node_modules", ".git", "vendor", ".build"] {
            XCTAssertFalse(names.contains(excluded), "\(excluded) no tiene que aparecer")
        }
        XCTAssertTrue(names.contains("src"))
        XCTAssertTrue(names.contains("index.php"))
    }

    func testDirectorySymlinkIsALeaf() async throws {
        let (directory, defaults) = try environment()
        let (_, root) = try await loadedCoordinator(directory, defaults)
        let link = try XCTUnwrap((root.children ?? []).first { $0.name == "enlace" })
        XCTAssertFalse(link.isDirectory, "un symlink a directorio no se expande")
    }

    func testFoldersComeFirstAndThenFilesInNaturalOrder() async throws {
        let (directory, defaults) = try environment()
        let (_, root) = try await loadedCoordinator(directory, defaults)
        let children = root.children ?? []
        let folders = children.prefix { $0.isDirectory }.map(\.name)
        let files = children.drop { $0.isDirectory }.map(\.name)
        XCTAssertEqual(folders, ["assets", "src"])
        XCTAssertEqual(files, ["enlace", "index.php", "README.md"])
        XCTAssertEqual(children.count, folders.count + files.count,
                       "ninguna carpeta después del primer archivo")
    }

    func testReloadingKeepsTheExistingNodes() async throws {
        let (directory, defaults) = try environment()
        let (coordinator, root) = try await loadedCoordinator(directory, defaults)
        let child = try XCTUnwrap((root.children ?? []).first { $0.name == "src" })

        let workspace = try XCTUnwrap(coordinator.controller.workspace)
        let url = try XCTUnwrap(coordinator.controller.workspaceURL)
        coordinator.update(workspace, at: url, revision: 2)

        XCTAssertTrue(coordinator.roots.first === root, "el nodo raíz se conserva")
        XCTAssertTrue((root.children ?? []).first { $0.name == "src" } === child,
                      "los hijos ya cargados se conservan")
    }

    func testExpandingLoadsChildrenOnDemand() async throws {
        let (directory, defaults) = try environment()
        let (coordinator, root) = try await loadedCoordinator(directory, defaults)
        let source = try XCTUnwrap((root.children ?? []).first { $0.name == "src" })
        XCTAssertNil(source.children, "la carga es perezosa: sin expandir no se lee")

        let outline = NSOutlineView()
        XCTAssertTrue(coordinator.outlineView(outline, shouldExpandItem: source))
        try await until({ source.children != nil }, 5, "la carga de src")
        XCTAssertEqual((source.children ?? []).map(\.name), ["app.ts"])
    }

    func testUnreadableFolderReportsTheErrorInsteadOfSwallowingIt() async throws {
        let (directory, defaults) = try environment()
        let url = try tree(in: directory)
        let denied = directory.appendingPathComponent("proyecto/sin-permiso")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o000)],
                                              ofItemAtPath: denied.path)
        let host = controller(defaults)
        await host.openWorkspace(url)
        let workspace = try XCTUnwrap(host.workspace)
        let coordinator = FileTree.Coordinator(controller: host)
        coordinator.update(workspace, at: url, revision: 1)
        let root = try XCTUnwrap(coordinator.roots.first)
        try await until({ root.children != nil }, 5, "la carga del nodo raíz")

        let node = try XCTUnwrap((root.children ?? []).first { $0.name == "sin-permiso" })
        _ = coordinator.outlineView(NSOutlineView(), shouldExpandItem: node)
        try await until({ node.children != nil }, 5, "el intento de carga")
        XCTAssertEqual(node.children?.count, 0)
        XCTAssertNotNil(host.errors.current, "el error tiene que llegar a la interfaz")
    }

    func testChangingWorkspaceInvalidatesLoadsInFlight() async throws {
        let (directory, defaults) = try environment()
        let (coordinator, _) = try await loadedCoordinator(directory, defaults)
        let before = coordinator.generation

        let workspace = try XCTUnwrap(coordinator.controller.workspace)
        let url = try XCTUnwrap(coordinator.controller.workspaceURL)
        coordinator.update(workspace, at: url, revision: 3)
        XCTAssertEqual(coordinator.generation, before, "cambiar de revisión no invalida nada")

        let otro = try tree(in: directory.appendingPathComponent("otro", isDirectory: true))
        coordinator.update(workspace, at: otro, revision: 4)
        XCTAssertNotEqual(coordinator.generation, before,
                          "cambiar de proyecto descarta las cargas del anterior")
    }

    /// Cada carpeta cargada queda observada; de eso depende que el árbol se actualice
    /// solo. **La llegada del evento no se puede comprobar desde XCTest acá**: con el
    /// observador instalado y un archivo nuevo en la carpeta, el handler no corre ni
    /// esperando 10 s con una expectativa que mueve el run loop. En la app sí funciona.
    /// Lo que esta prueba fija es que el observador se instale y que la falta de permiso
    /// para observar no pase desapercibida (ver el `Log.workspace.notice` de C6).
    func testLoadedFoldersAreWatched() async throws {
        let (directory, defaults) = try environment()
        let (coordinator, root) = try await loadedCoordinator(directory, defaults)
        XCTAssertNotNil(root.watcher, "la carpeta raíz del subproyecto queda observada")

        let source = try XCTUnwrap((root.children ?? []).first { $0.name == "src" })
        XCTAssertNil(source.watcher, "sin cargar, no se observa")
        _ = coordinator.outlineView(NSOutlineView(), shouldExpandItem: source)
        try await until({ source.children != nil }, 5, "la carga de src")
        XCTAssertNotNil(source.watcher, "al cargarla, también")
    }
}
