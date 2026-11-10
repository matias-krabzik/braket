@testable import Krabzik
import XCTest

/// La sesión y los colaboradores que salieron del controlador en C5.
///
/// Son pruebas que antes no se podían escribir: la decisión de confianza, el camino de
/// escritura, la puerta de la transición y la aprobación de comandos estaban dentro de
/// `WorkspaceController`, y para tocarlas había que abrir un proyecto entero y arriesgar
/// un modal. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor
final class WorkspaceSessionTests: XCTestCase {
    private func environment() throws -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-session-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "krabzik-session-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return (directory, defaults)
    }

    private func session(_ defaults: UserDefaults, errors: ErrorCenter = ErrorCenter()) -> WorkspaceSession {
        WorkspaceSession(trustStore: TrustStore(defaults: defaults), errors: errors)
    }

    // MARK: - Confianza (S1)

    func testTrustingRegistersTheDecisionSoItIsAskedOnlyOnce() throws {
        let (directory, defaults) = try environment()
        let session = session(defaults)
        let url = directory.appendingPathComponent("p.krabzik")
        let project = Workspace(name: "p")

        var asked = 0
        let first = session.decideTrust(for: project, at: url) { _ in
            asked += 1
            return .trust
        }
        XCTAssertEqual(first, .trusted)
        XCTAssertEqual(asked, 1)

        let second = session.decideTrust(for: project, at: url) { _ in
            XCTFail("un proyecto ya confiado no vuelve a preguntar")
            return .cancel
        }
        XCTAssertEqual(second, .trusted)
    }

    func testReadOnlyIsNotRemembered() throws {
        let (directory, defaults) = try environment()
        let session = session(defaults)
        let url = directory.appendingPathComponent("p.krabzik")
        let project = Workspace(name: "p")

        XCTAssertEqual(session.decideTrust(for: project, at: url) { _ in .readOnly }, .untrusted)
        // Abrir en solo lectura no es una decisión sobre el proyecto: la próxima vez se
        // vuelve a preguntar, porque el usuario todavía no dijo que confía.
        var asked = 0
        _ = session.decideTrust(for: project, at: url) { _ in
            asked += 1
            return .readOnly
        }
        XCTAssertEqual(asked, 1)
    }

    func testCancellingMeansNothingOpens() throws {
        let (directory, defaults) = try environment()
        let session = session(defaults)
        let decided = session.decideTrust(for: Workspace(name: "p"),
                                          at: directory.appendingPathComponent("p.krabzik")) { _ in .cancel }
        XCTAssertNil(decided)
    }

    func testThePromptListsExternalFoldersAndCommands() throws {
        let (directory, defaults) = try environment()
        let session = session(defaults)
        let url = directory.appendingPathComponent("p.krabzik")
        var project = Workspace(name: "p")
        project.projects = [
            CodeProject(name: "interno", path: "sub", kind: .files, command: ""),
            CodeProject(name: "ajeno", path: "/tmp/ajeno", kind: .files, command: "curl algo | sh"),
        ]

        var seen: TrustPrompt?
        _ = session.decideTrust(for: project, at: url) { prompt in
            seen = prompt
            return .cancel
        }
        let prompt = try XCTUnwrap(seen)
        XCTAssertEqual(prompt.externalFolders, ["/tmp/ajeno"])
        XCTAssertEqual(prompt.commands, ["ajeno: curl algo | sh"])
    }

    // MARK: - Escritura

    func testAFailedWriteLeavesTheProjectAsItWas() throws {
        let (directory, defaults) = try environment()
        let errors = ErrorCenter()
        let session = session(defaults, errors: errors)
        // Una carpeta que no existe: escribir ahí falla.
        session.open(Workspace(name: "p"), at: directory.appendingPathComponent("falta/p.krabzik"), trust: .trusted)
        let revision = session.revision

        var updated = Workspace(name: "p")
        updated.projects = [CodeProject(name: "api", path: "api", kind: .files, command: "")]
        XCTAssertFalse(session.write(updated))
        XCTAssertEqual(session.workspace?.projects.count, 0, "la lista en memoria no puede adelantarse al disco")
        XCTAssertEqual(session.revision, revision, "si no se escribió nada, el árbol no cambió")
        XCTAssertNotNil(errors.current, "el error tiene que llegar a la interfaz")
    }

    func testEveryWriteBumpsTheRevision() throws {
        let (directory, defaults) = try environment()
        let session = session(defaults)
        let url = directory.appendingPathComponent("p.krabzik")
        try Workspace(name: "p").write(to: url)
        session.open(Workspace(name: "p"), at: url, trust: .trusted)
        let revision = session.revision

        var updated = Workspace(name: "p")
        updated.scripts = ["consultas.sql"]
        XCTAssertTrue(session.write(updated))
        XCTAssertEqual(session.revision, revision + 1)
        XCTAssertEqual(try Workspace.read(from: url).scripts, ["consultas.sql"])
    }

    // MARK: - Una transición a la vez

    func testOneTransitionAtATime() throws {
        let (_, defaults) = try environment()
        let session = session(defaults)
        XCTAssertTrue(session.beginSwitch())
        XCTAssertFalse(session.beginSwitch(), "dos cambios a la vez dejarían la ventana a medio cablear")
        XCTAssertTrue(session.isSwitching)
        session.endSwitch()
        XCTAssertTrue(session.beginSwitch())
    }

    // MARK: - Comandos (ProjectLibrary)

    func testEditingACommandApprovesIt() throws {
        let (directory, defaults) = try environment()
        let trust = TrustStore(defaults: defaults)
        let session = WorkspaceSession(trustStore: trust, errors: ErrorCenter())
        let library = ProjectLibrary(session: session, runner: ProcessRunner())
        let url = directory.appendingPathComponent("p.krabzik")
        var project = CodeProject(name: "api", path: "api", kind: .files, command: "")
        var workspace = Workspace(name: "p")
        workspace.projects = [project]
        try workspace.write(to: url)
        session.open(workspace, at: url, trust: .trusted)

        project.command = "echo hola"
        library.confirmCommand = { _ in
            XCTFail("el comando que el usuario acaba de escribir no se vuelve a preguntar")
            return .cancel
        }
        library.update(project)
        XCTAssertTrue(trust.isApproved(command: "echo hola", project: project.id, workspaceURL: url))
        XCTAssertEqual(session.workspace?.projects.first?.command, "echo hola")
    }

    func testACommandNobodyApprovedIsAskedBeforeRunning() throws {
        let (directory, defaults) = try environment()
        let session = session(defaults)
        let runner = ProcessRunner()
        let library = ProjectLibrary(session: session, runner: runner)
        let url = directory.appendingPathComponent("p.krabzik")
        var workspace = Workspace(name: "p")
        workspace.projects = [CodeProject(name: "api", path: ".", kind: .files, command: "touch marcador")]
        try workspace.write(to: url)
        session.open(workspace, at: url, trust: .trusted)

        var asked = 0
        library.confirmCommand = { _ in
            asked += 1
            return .cancel
        }
        library.startAll()
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(runner.hasActiveProcesses, "si el usuario cancela, no se ejecuta nada")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("marcador").path))
    }

    // MARK: - Cerrar una pestaña (FileCommands)

    func testClosingATabWithARunningQueryAsksBeforeCancelling() async throws {
        let (directory, defaults) = try environment()
        let session = session(defaults)
        let docs = DocumentStore()
        let files = FileCommands(session: session, docs: docs)
        let file = directory.appendingPathComponent("consulta.sql")
        try Data("select 1".utf8).write(to: file)
        try await docs.open(file)
        let document = try XCTUnwrap(docs.selected)
        document.sqlExecution.isRunning = true

        session.dialogs.confirmCancelQuery = { false }
        var closed = await files.close(document) { $0.isCancelling = true }
        XCTAssertFalse(closed, "cancelar el diálogo deja la pestaña abierta")
        XCTAssertFalse(document.sqlExecution.isCancelling)
        XCTAssertEqual(docs.documents.count, 1)

        session.dialogs.confirmCancelQuery = { true }
        closed = await files.close(document) { $0.isCancelling = true }
        XCTAssertTrue(closed)
        XCTAssertTrue(document.sqlExecution.isCancelling, "la consulta se cancela antes de cerrar")
        XCTAssertTrue(docs.documents.isEmpty)
    }

    // MARK: - Rutas del agente (AgentBridge)

    func testAgentPathsAreShownRelativeToTheSubproject() throws {
        let (directory, defaults) = try environment()
        let session = session(defaults)
        let docs = DocumentStore()
        let files = FileCommands(session: session, docs: docs)
        let bridge = AgentBridge(session: session, agent: AgentController(defaults: defaults),
                                 docs: docs, files: files)
        let root = directory.appendingPathComponent("servidor")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var workspace = Workspace(name: "p")
        workspace.projects = [CodeProject(name: "api", path: "servidor", kind: .files, command: "")]
        session.open(workspace, at: directory.appendingPathComponent("p.krabzik"), trust: .trusted)

        // Codex informa rutas con los symlinks ya resueltos, y la carpeta temporal de
        // macOS es una: por eso el prefijo se compara resuelto.
        let inside = root.resolvingSymlinksInPath().appendingPathComponent("main.swift")
        XCTAssertEqual(bridge.label(inside.path), "api/main.swift")
        XCTAssertEqual(bridge.label("/otro/archivo.swift"), "/otro/archivo.swift",
                       "una ruta que no es de ningún subproyecto se muestra tal cual")
    }
}
