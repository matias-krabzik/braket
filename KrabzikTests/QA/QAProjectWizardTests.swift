@testable import Krabzik
import XCTest

/// Suite PRJ del catálogo: el asistente de creación, paso por paso.
///
/// El asistente es una vista con su propio estado, así que los escenarios que afirman
/// qué ofrece la pantalla —qué botón está habilitado y con qué texto— lo montan de
/// verdad; los que afirman lo que queda en disco van por `createWorkspace(from:)`, que es
/// la acción que ejecuta el botón «Crear proyecto».
@MainActor
final class QAProjectWizardTests: XCTestCase {
    private func draft(_ qa: QAHarness, name: String) -> ProjectDraft {
        var draft = ProjectDraft()
        draft.name = name
        draft.libraryRoot = qa.root.appendingPathComponent("Biblioteca", isDirectory: true)
        return draft
    }

    /// PRJ-01
    func testCreateOpensTheWizardOnItsFirstStep() async throws {
        let qa = try QAHarness(self)
        await qa.mount()
        try await qa.tap("welcome.create")
        await qa.assertEvent("wizard.open.request", ["switching": "false"])
        await qa.assertScreen("wizard")
        await qa.assertControl("wizard.step.0", title: "Proyecto", enabled: true)
        await qa.assertControl("wizard.step.1", title: "Subproyectos", enabled: false)
        await qa.assertControl("wizard.step.2", title: "Resumen", enabled: false)
    }

    /// PRJ-02, PRJ-03
    func testTheWizardRefusesToAdvanceWithoutAValidName() async throws {
        let qa = try QAHarness(self)
        await qa.mount()
        try await qa.tap("welcome.create")
        await qa.assertScreen("wizard")
        await qa.assertControl("wizard.next", title: "Continuar", enabled: false)
        await qa.assertControl("wizard.create", title: "Crear ahora", enabled: false)

        var empty = draft(qa, name: "   ")
        XCTAssertEqual(empty.validationMessage, "Ingresá un nombre para el proyecto.")
        empty.name = "a/b"
        XCTAssertEqual(empty.validationMessage, "El nombre no puede contener /, : ni caracteres de control.")
        empty.name = "a:b"
        XCTAssertNotNil(empty.validationMessage)
        empty.name = "a\u{0}b"
        XCTAssertNotNil(empty.validationMessage)
    }

    /// PRJ-04
    func testAValidNameEnablesEveryStep() async throws {
        let qa = try QAHarness(self)
        var valid = draft(qa, name: "Tienda")
        XCTAssertNil(valid.validationMessage)
        valid.name = String(repeating: "a", count: WorkspaceLimits.nameLength + 1)
        XCTAssertEqual(valid.validationMessage, "Elegí un nombre más corto.")
    }

    /// PRJ-05
    func testTheWizardRefusesAnExistingProjectFile() async throws {
        let qa = try QAHarness(self)
        var first = draft(qa, name: "Tienda")
        first.openWhenCreated = false
        let created = try await qa.controller.createWorkspace(from: first)
        XCTAssertTrue(created)
        let again = draft(qa, name: "Tienda")
        XCTAssertEqual(again.validationMessage, "Ya existe un proyecto con ese nombre en esta ubicación.")
        do {
            _ = try await qa.controller.createWorkspace(from: again)
            XCTFail("no puede crear dos veces el mismo proyecto")
        } catch {
            await qa.assertEvent("project.create.rejected")
        }
    }

    /// PRJ-06
    func testAddingFoldersDetectsSubprojects() async throws {
        let qa = try QAHarness(self)
        let node = qa.root.appendingPathComponent("web", isDirectory: true)
        let swift = qa.root.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: node.appendingPathComponent("package.json"))
        try Data("// swift-tools-version:6.0".utf8).write(to: swift.appendingPathComponent("Package.swift"))
        let detected = try ProjectDraft.detect([node, swift])
        XCTAssertEqual(detected.count, 2)
        XCTAssertEqual(Set(detected.map(\.name)), ["web", "app"])
        XCTAssertEqual(try ProjectDraft.detect([node, node]).count, 1, "la misma carpeta no entra dos veces")
    }

    /// PRJ-08
    func testCreatingAProjectOpensItTrusted() async throws {
        let qa = try QAHarness(self)
        await qa.mount()
        var draft = draft(qa, name: "Tienda")
        draft.openWhenCreated = true
        let created = try await qa.controller.createWorkspace(from: draft)
        XCTAssertTrue(created)
        await qa.settle(until: { qa.controller.workspace != nil })
        await qa.assertEvent("project.create.ok", ["name": "Tienda", "opening": "true"])
        await qa.assertEvent("state.workspace", ["name": "Tienda", "readOnly": "false"])
        XCTAssertFalse(qa.controller.isReadOnly)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.url.path))
        XCTAssertEqual(qa.controller.recentProjects.first?.standardizedFileURL, draft.url.standardizedFileURL)
        await qa.assertScreen("welcome", present: false)
    }

    /// PRJ-09
    func testCreatingWithoutOpeningKeepsTheWelcomeScreen() async throws {
        let qa = try QAHarness(self)
        await qa.mount()
        var draft = draft(qa, name: "Tienda")
        draft.openWhenCreated = false
        let created = try await qa.controller.createWorkspace(from: draft)
        XCTAssertTrue(created)
        await qa.assertEvent("project.create.ok", ["opening": "false"])
        XCTAssertNil(qa.controller.workspace)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.url.path))
        await qa.assertScreen("welcome")
    }

    /// PRJ-10
    func testCreatingNeverOverwritesAFileThatAppearedMeanwhile() async throws {
        let qa = try QAHarness(self)
        var draft = draft(qa, name: "Tienda")
        draft.openWhenCreated = false
        try FileManager.default.createDirectory(at: draft.folder, withIntermediateDirectories: true)
        try Data("ajeno".utf8).write(to: draft.url)
        do {
            _ = try await qa.controller.createWorkspace(from: draft)
            XCTFail("tiene que fallar antes de escribir")
        } catch {
            let kept = try String(contentsOf: draft.url, encoding: .utf8)
            XCTAssertEqual(kept, "ajeno", "el archivo que estaba no se toca")
        }
    }

    /// PRJ-11
    func testCancellingTheWizardWritesNothing() async throws {
        let qa = try QAHarness(self)
        await qa.mount()
        try await qa.tap("welcome.create")
        await qa.assertScreen("wizard")
        try await qa.tap("wizard.cancel")
        await qa.settle(until: { !qa.controller.showingProjectWizard })
        XCTAssertFalse(qa.controller.showingProjectWizard, "cancelar cierra el asistente")
        let library = qa.root.appendingPathComponent("Biblioteca", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path), "no se crea la carpeta de la biblioteca")
        XCTAssertNil(qa.controller.workspace, "no quedó ningún proyecto abierto")
    }

    /// PRJ-12
    func testCreatingApprovesDeclaredCommandsWithoutRunningThem() async throws {
        let qa = try QAHarness(self)
        let folder = qa.root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var draft = draft(qa, name: "ConComando")
        draft.projects = [CodeProject(name: "api", path: folder.path, kind: .files, command: "npm start")]
        draft.openWhenCreated = true
        let created = try await qa.controller.createWorkspace(from: draft)
        XCTAssertTrue(created)
        let project = try XCTUnwrap(qa.controller.workspace?.projects.first)
        XCTAssertTrue(qa.controller.trust.isApproved(command: "npm start", project: project.id,
                                                     workspaceURL: draft.url),
                      "el comando declarado queda aprobado al crear el proyecto")
        XCTAssertFalse(qa.controller.runner.hasActiveProcesses, "crear un proyecto no ejecuta nada")
    }
}
