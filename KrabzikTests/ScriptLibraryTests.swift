@testable import Krabzik
import XCTest

/// Las dos funciones puras de la lista de scripts SQL. Antes eran dos métodos del
/// controlador que necesitaban un proyecto abierto para ejercitarse.
/// Ver docs/specs/C5-dividir-workspacecontroller.md.
final class ScriptLibraryTests: XCTestCase {
    private let workspaceURL = URL(fileURLWithPath: "/proyectos/tienda/Tienda.kzk")

    private func workspace(scripts: [String] = [], projects: [CodeProject] = []) -> Workspace {
        var value = Workspace(name: "Tienda", projects: projects)
        value.scripts = scripts
        return value
    }

    func testRelativePathResolvesAgainstTheProjectFolder() {
        let url = ScriptLibrary.url(for: "sql/consultas.sql", workspaceURL: workspaceURL, trust: .trusted)
        XCTAssertEqual(url?.path, "/proyectos/tienda/sql/consultas.sql")
    }

    func testAbsolutePathIsKept() {
        let url = ScriptLibrary.url(for: "/otra/parte/x.sql", workspaceURL: workspaceURL, trust: .trusted)
        XCTAssertEqual(url?.path, "/otra/parte/x.sql")
    }

    /// Un `.kzk` que no se confió no puede hacer que el IDE abra archivos de
    /// cualquier parte del disco.
    func testExternalScriptIsRefusedWhenUntrusted() {
        XCTAssertNil(ScriptLibrary.url(for: "/etc/passwd", workspaceURL: workspaceURL, trust: .untrusted))
        XCTAssertNil(ScriptLibrary.url(for: "../../etc/passwd", workspaceURL: workspaceURL, trust: .untrusted))
        XCTAssertNotNil(ScriptLibrary.url(for: "sql/propio.sql", workspaceURL: workspaceURL, trust: .untrusted),
                        "lo de adentro sí se abre")
    }

    func testRemembersRelativePathForScriptsUnderTheProject() throws {
        let url = URL(fileURLWithPath: "/proyectos/tienda/sql/nuevo.sql")
        let updated = try XCTUnwrap(ScriptLibrary.remembering(url, in: workspace(), at: workspaceURL))
        XCTAssertEqual(updated.scripts, ["sql/nuevo.sql"])
    }

    func testRemembersAbsolutePathForScriptsOutside() throws {
        let url = URL(fileURLWithPath: "/otra/parte/nuevo.sql")
        let updated = try XCTUnwrap(ScriptLibrary.remembering(url, in: workspace(), at: workspaceURL))
        XCTAssertEqual(updated.scripts, ["/otra/parte/nuevo.sql"])
    }

    func testIgnoresWhatIsNotSQL() {
        let url = URL(fileURLWithPath: "/proyectos/tienda/notas.txt")
        XCTAssertNil(ScriptLibrary.remembering(url, in: workspace(), at: workspaceURL))
    }

    func testIgnoresOneAlreadyInTheList() {
        let url = URL(fileURLWithPath: "/proyectos/tienda/sql/a.sql")
        XCTAssertNil(ScriptLibrary.remembering(url, in: workspace(scripts: ["sql/a.sql"]), at: workspaceURL))
    }

    /// Dentro de un subproyecto ya lo muestra el explorador: repetirlo sería ruido.
    func testIgnoresOneInsideASubproject() {
        let project = CodeProject(name: "api", path: "api", kind: .files, command: "")
        let url = URL(fileURLWithPath: "/proyectos/tienda/api/migracion.sql")
        XCTAssertNil(ScriptLibrary.remembering(url, in: workspace(projects: [project]), at: workspaceURL))
    }
}
