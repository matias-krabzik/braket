import Darwin
import Foundation
@testable import Krabzik
import XCTest

/// Bordes del ciclo de vida de un proceso gestionado: lo que no arranca, cómo termina,
/// qué pasa con los hijos que dejó, y las dos puertas —confianza y aprobación del
/// comando— que deciden si algo llega a ejecutarse.
///
/// Son procesos reales y cortos. Cada prueba limpia lo que lanzó, y `terminateImmediately`
/// en el teardown es la red por si una afirmación falla antes del `stop`.
@MainActor
final class ProcessLifecycleTests: XCTestCase {
    // MARK: - Nada que ejecutar

    func testBlankCommandAndUnavailableFolderNeverSpawn() throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("Procesos.kzk")
        let runner = try runner()

        let blank = CodeProject(name: "Vacío", path: ".", kind: .files, command: "   \n ")
        runner.start(blank, workspaceURL: url)
        let blankRun = runner.state(for: blank, workspaceURL: url)
        XCTAssertEqual(blankRun.status, .idle)
        XCTAssertEqual(blankRun.output, "")
        XCTAssertEqual(blankRun.processID, 0)
        XCTAssertFalse(runner.hasActiveProcesses)

        let missing = CodeProject(name: "Perdido", path: "no-existe", kind: .files, command: "echo hola")
        runner.start(missing, workspaceURL: url)
        let missingRun = runner.state(for: missing, workspaceURL: url)
        XCTAssertEqual(missingRun.status, .failed("Carpeta no disponible"))
        XCTAssertTrue(missingRun.output.contains("no-existe"), missingRun.output)
        XCTAssertEqual(missingRun.processID, 0)

        // Un archivo donde se espera una carpeta: `fileExists` sola diría que sí.
        try Data("x".utf8).write(to: root.appendingPathComponent("archivo.txt"))
        let file = CodeProject(name: "Archivo", path: "archivo.txt", kind: .files, command: "echo hola")
        runner.start(file, workspaceURL: url)
        XCTAssertEqual(runner.state(for: file, workspaceURL: url).status, .failed("Carpeta no disponible"))
        XCTAssertFalse(runner.hasActiveProcesses)
    }

    // MARK: - Cómo termina

    func testExitCodesCoverSuccessFailureAndSignal() async throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("Procesos.kzk")
        let runner = try runner()
        for (command, expected) in [("exit 0", RunStatus.exited(0)), ("exit 7", .exited(7)),
                                    ("kill -TERM $$", .exited(143))] {
            let project = CodeProject(name: "Salida", path: ".", kind: .files, command: command)
            runner.start(project, workspaceURL: url)
            let run = runner.state(for: project, workspaceURL: url)
            let finished = await waitUntil { run.status == expected }
            XCTAssertTrue(finished, "«\(command)» terminó en \(run.status)")
            XCTAssertEqual(run.processID, 0)
            XCTAssertNotNil(run.endedAt)
            XCTAssertFalse(run.pendingRestart)
        }
    }

    func testStopEndsTheWholeProcessGroup() async throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("Procesos.kzk")
        let runner = try runner()
        // El hijo que deja el comando —el `npm` que lanza un `node`— tiene que caer con él.
        let project = CodeProject(name: "Grupo", path: ".", kind: .files,
                                  command: "sleep 45 & echo \"hijo $!\"; wait")
        runner.start(project, workspaceURL: url)
        let run = runner.state(for: project, workspaceURL: url)
        // El encabezado `$ comando` ya contiene «hijo »: hay que esperar la línea impresa.
        let announced = await waitUntil { self.childProcessID(in: run.output) != nil }
        XCTAssertTrue(announced, run.output)
        let child = try XCTUnwrap(childProcessID(in: run.output))
        XCTAssertEqual(Darwin.kill(child, 0), 0, "el hijo no llegó a arrancar")

        runner.stop(run.id)
        let stopped = await waitUntil { !run.status.active }
        XCTAssertTrue(stopped, "estado \(run.status)")
        XCTAssertEqual(run.status, .idle)
        XCTAssertEqual(run.processID, 0)
        XCTAssertTrue(run.output.hasSuffix("\nProceso detenido.\n"), run.output)
        XCTAssertEqual(Darwin.kill(child, 0), -1, "el hijo del grupo sobrevivió al stop")
        XCTAssertEqual(errno, ESRCH)
    }

    func testStopForcesAProcessThatIgnoresSIGTERM() async throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("Procesos.kzk")
        let runner = try runner()
        let project = CodeProject(name: "Terco", path: ".", kind: .files,
                                  command: "trap '' TERM; while true; do sleep 1; done")
        runner.start(project, workspaceURL: url)
        let run = runner.state(for: project, workspaceURL: url)
        XCTAssertEqual(run.status, .running)
        runner.stop(run.id)
        XCTAssertEqual(run.status, .stopping)
        let killed = await waitUntil({ !run.status.active }, timeout: 20)
        XCTAssertTrue(killed, "el SIGKILL automático no llegó · estado \(run.status)")
        XCTAssertEqual(run.status, .idle)
    }

    // MARK: - Reinicio automático

    func testRestartOnFailureGivesUpAfterThreeAttempts() async throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("Procesos.kzk")
        let runner = try runner()
        var configuration = RunConfiguration()
        configuration.restartPolicy = .onFailure
        let project = CodeProject(name: "Caído", path: ".", kind: .files, command: "exit 1",
                                  runConfiguration: configuration)
        runner.start(project, workspaceURL: url)
        let run = runner.state(for: project, workspaceURL: url)
        let exhausted = await waitUntil({ run.restartAttempts == 3 && !run.pendingRestart && run.status == .exited(1) },
                                        timeout: 40)
        XCTAssertTrue(exhausted, "intentos \(run.restartAttempts) · estado \(run.status)")
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(run.restartAttempts, 3, "hubo un cuarto intento")
        XCTAssertEqual(run.status, .exited(1))
        XCTAssertFalse(runner.hasActiveProcesses)
    }

    func testManualRestartResetsTheAttemptCounter() async throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("Procesos.kzk")
        let runner = try runner()
        let project = CodeProject(name: "Servidor", path: ".", kind: .files, command: "sleep 45")
        runner.start(project, workspaceURL: url)
        let run = runner.state(for: project, workspaceURL: url)
        XCTAssertEqual(run.status, .running)
        let first = run.processID
        run.restartAttempts = 2

        runner.restart(run, project: project)
        let relaunched = await waitUntil({ run.status == .running && run.processID != 0 && run.processID != first },
                                         timeout: 20)
        XCTAssertTrue(relaunched, "estado \(run.status) · pid \(run.processID)")
        XCTAssertEqual(run.restartAttempts, 0)
        XCTAssertFalse(run.pendingRestart)
        runner.stop(run.id)
        let stopped = await waitUntil({ !run.status.active }, timeout: 20)
        XCTAssertTrue(stopped, "estado \(run.status)")
    }

    // MARK: - Salida

    func testEnvironmentOverridesWinAndColourIsDisabled() async throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("Procesos.kzk")
        let runner = try runner()
        var configuration = RunConfiguration()
        configuration.environment = ["MI_VAR": "de la configuración"]
        let project = CodeProject(name: "Entorno", path: ".", kind: .files,
                                  command: "printf '%s|%s|%s\\n' \"$MI_VAR\" \"$NO_COLOR\" \"$TERM\"",
                                  runConfiguration: configuration)
        runner.start(project, workspaceURL: url)
        let run = runner.state(for: project, workspaceURL: url)
        let first = await waitUntil { run.status == .exited(0) }
        XCTAssertTrue(first, "estado \(run.status)")
        XCTAssertTrue(run.output.contains("de la configuración|1|dumb"), run.output)
        // La cabecera `$ comando` es de la interfaz: no es salida del proceso.
        XCTAssertTrue(run.output.hasPrefix("$ " + project.executionCommand + "\n"), run.output)
        XCTAssertFalse(run.capturedOutput.contains("$ printf"), run.capturedOutput)

        runner.start(project, workspaceURL: url, environment: ["MI_VAR": "del arranque"])
        let second = await waitUntil { run.status == .exited(0) && run.output.contains("del arranque") }
        XCTAssertTrue(second, run.output)
        XCTAssertFalse(run.output.contains("de la configuración"), "la salida anterior no se limpió")
    }

    func testOutputIsCappedAndTheDecoderJoinsSplitCharacters() {
        let run = ProjectRun(id: UUID())
        run.append(String(repeating: "x", count: 150_000))
        XCTAssertEqual(run.output.count, 150_000)
        run.append(String(repeating: "y", count: 150_000))
        XCTAssertEqual(run.output.count, 120_000, "la salida no se recortó")
        XCTAssertTrue(run.output.hasSuffix("y"))
        XCTAssertEqual(run.revision, 2)

        // Una lectura de la tubería puede cortar un carácter de varios bytes al medio.
        var decoder = UTF8StreamDecoder()
        XCTAssertEqual(decoder.decode(Data()), "")
        XCTAssertEqual(decoder.decode(Data("hola".utf8)), "hola")
        let accent = Array("á".utf8)
        XCTAssertEqual(accent.count, 2)
        XCTAssertEqual(decoder.decode(Data(accent.prefix(1))), "")
        XCTAssertEqual(decoder.decode(Data(accent.suffix(1))), "á")
        let crab = Array("🦀".utf8)
        XCTAssertEqual(crab.count, 4)
        XCTAssertEqual(decoder.decode(Data(crab[0..<2])), "")
        XCTAssertEqual(decoder.decode(Data(crab[2..<3])), "")
        XCTAssertEqual(decoder.decode(Data(crab[3...])), "🦀")
        // Basura binaria: un reemplazo, y lo que sigue se decodifica igual.
        XCTAssertEqual(decoder.decode(Data([0xFF])), "\u{FFFD}")
        XCTAssertEqual(decoder.decode(Data([0x80])), "\u{FFFD}")
        // Un prefijo que nunca se completa no deja el flujo trabado.
        XCTAssertEqual(decoder.decode(Data([0xC3])), "")
        XCTAssertTrue(decoder.decode(Data("fin".utf8)).hasSuffix("fin"))
    }

    // MARK: - Puertas de confianza y aprobación

    func testStartManagedProcessNeedsTrustAndAnApprovedCommand() async throws {
        let project = CodeProject(name: "Servidor", path: ".", kind: .files, command: "sleep 45")
        var asked = 0
        let cancel: @MainActor (CommandPrompt) -> CommandDecision = { _ in
            asked += 1
            return .cancel
        }

        // Un proyecto abierto en solo lectura no ejecuta nada, y ni siquiera llega a
        // preguntar por el comando: la puerta de confianza va primero.
        let (readOnly, readOnlyURL) = try await workspace(with: [project], trusted: false)
        readOnly.projects.confirmCommand = cancel
        let readOnlyRun = readOnly.runner.state(for: project, workspaceURL: readOnlyURL)
        readOnly.startManagedProcess(readOnlyRun)
        XCTAssertEqual(readOnlyRun.status, .idle, "arrancó un proceso de un proyecto en solo lectura")
        XCTAssertEqual(asked, 0, "preguntó por el comando sin tener confianza")
        XCTAssertNotNil(readOnly.errors.current, "no avisó por qué no arrancó")

        let (controller, url) = try await workspace(with: [project])
        controller.projects.confirmCommand = cancel
        let run = controller.runner.state(for: project, workspaceURL: url)
        controller.startManagedProcess(run)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(run.status, .idle, "arrancó un comando que se canceló en el diálogo")

        controller.projects.confirmCommand = { prompt in
            XCTAssertEqual(prompt.command, project.commandApproval)
            asked += 1
            return .always
        }
        controller.startManagedProcess(run)
        XCTAssertEqual(asked, 2)
        let running = await waitUntil { run.status == .running }
        XCTAssertTrue(running, "estado \(run.status)")
        XCTAssertTrue(controller.trust.isApproved(command: project.commandApproval, project: project.id,
                                                  workspaceURL: url))
        controller.runner.stop(run.id)
        let stopped = await waitUntil({ !run.status.active }, timeout: 20)
        XCTAssertTrue(stopped, "estado \(run.status)")

        // El subproyecto desapareció del `.kzk` mientras el panel seguía abierto.
        try Workspace(name: "Procesos").write(to: url)
        controller.startManagedProcess(run)
        XCTAssertEqual(run.status, .idle)
        XCTAssertEqual(asked, 2)
    }

    func testSaveRunConfigurationKeepsUnrelatedEditsAndApprovesTheNewCommand() async throws {
        let project = CodeProject(name: "Servidor", path: ".", kind: .files, command: "node old.js")
        let (controller, url) = try await workspace(with: [project])
        let run = controller.runner.state(for: project, workspaceURL: url)
        var updated = project
        updated.command = "node server.js"
        var configuration = RunConfiguration()
        configuration.arguments = ["--port", "3000"]
        configuration.environment = ["NODE_ENV": "development"]
        configuration.expectedPort = 3000
        updated.runConfiguration = configuration

        controller.trust.forget(url)
        XCTAssertFalse(controller.saveRunConfiguration(updated, for: run, restart: false),
                       "guardó la configuración de un proyecto en solo lectura")
        XCTAssertEqual(try Workspace.read(from: url).projects.first?.command, "node old.js")

        controller.trust.markTrusted(url)
        // Alguien editó el archivo por fuera mientras la hoja estaba abierta: guardar la
        // configuración no puede pisar lo que no toca.
        var external = try Workspace.read(from: url)
        external.name = "Renombrado"
        external.projects.append(CodeProject(name: "Otro", path: ".", kind: .files, command: "make"))
        try external.write(to: url)

        XCTAssertTrue(controller.saveRunConfiguration(updated, for: run, restart: false))
        let saved = try Workspace.read(from: url)
        XCTAssertEqual(saved.name, "Renombrado")
        XCTAssertEqual(saved.projects.map(\.name), ["Servidor", "Otro"])
        XCTAssertEqual(saved.projects.first?.command, "node server.js")
        XCTAssertEqual(saved.projects.first?.runConfiguration, configuration)
        XCTAssertEqual(controller.openWorkspaceModels[url.standardizedFileURL]?.name, "Renombrado")
        XCTAssertEqual(run.project?.command, "node server.js")
        // El comando nuevo queda aprobado al guardarlo, y el viejo deja de estarlo.
        XCTAssertTrue(controller.trust.isApproved(command: updated.commandApproval, project: project.id,
                                                  workspaceURL: url))
        XCTAssertFalse(controller.trust.isApproved(command: project.commandApproval, project: project.id,
                                                   workspaceURL: url))

        var ghost = updated
        ghost.id = UUID()
        XCTAssertFalse(controller.saveRunConfiguration(ghost, for: run, restart: false),
                       "guardó la configuración de un subproyecto que no está en el archivo")
    }

    func testSaveRunConfigurationRejectsWhatTheReaderWouldNotAccept() async throws {
        let project = CodeProject(name: "Servidor", path: ".", kind: .files, command: "node old.js")
        let (controller, url) = try await workspace(with: [project])
        let run = controller.runner.state(for: project, workspaceURL: url)
        var invalid = project
        var configuration = RunConfiguration()
        // Un argumento pegado de más: el editor no mide su largo, la lectura sí.
        configuration.arguments = [String(repeating: "a", count: 20_000)]
        invalid.runConfiguration = configuration

        XCTAssertFalse(controller.saveRunConfiguration(invalid, for: run, restart: false),
                       "escribió un .kzk que después no se puede abrir")
        let saved = try Workspace.read(from: url)
        XCTAssertEqual(saved.projects.first?.command, "node old.js")
        XCTAssertNil(saved.projects.first?.runConfiguration)
        XCTAssertNotNil(controller.errors.current, "falló en silencio")
    }

    // MARK: - Puertos

    func testPortConflictNamesTheProcessHoldingThePort() async throws {
        let (descriptor, port) = try listeningSocket()
        var closed = false
        defer {
            if !closed { Darwin.close(descriptor) }
        }
        var configuration = RunConfiguration()
        configuration.expectedPort = port
        let project = CodeProject(name: "Servidor", path: ".", kind: .files, command: "sleep 45",
                                  runConfiguration: configuration)
        let (controller, url) = try await workspace(with: [project])
        let run = controller.runner.state(for: project, workspaceURL: url)

        await controller.refreshManagedPorts()
        let listeners = controller.processManager.listeners
        XCTAssertEqual(listeners.map(\.port), listeners.map(\.port).sorted(), "los puertos no vienen ordenados")
        XCTAssertEqual(Set(listeners.map(\.id)).count, listeners.count, "hay escuchas repetidas")
        let mine = try XCTUnwrap(listeners.first { $0.port == port }, "no vio el puerto que abrió la prueba")
        XCTAssertEqual(mine.pid, getpid())
        XCTAssertFalse(mine.command.isEmpty)
        XCTAssertEqual(run.ports, [], "un proceso detenido no tiene puertos propios")
        XCTAssertEqual(run.portConflict, "Puerto \(port) ocupado por \(mine.command) (PID \(mine.pid))")

        Darwin.close(descriptor)
        closed = true
        await controller.refreshManagedPorts()
        XCTAssertEqual(run.portConflict, "", "el conflicto siguió después de liberar el puerto")
    }

    // MARK: - Panel

    func testDockingTheProcessPanelMakesItVisible() async throws {
        let (controller, _) = try await workspace(with: [])
        let defaults = UserDefaults.standard
        let key = "processManager.detached"
        let hadValue = defaults.object(forKey: key) != nil
        let previous = defaults.bool(forKey: key)
        addTeardownBlock { @MainActor in
            if hadValue { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        controller.processesVisible = false
        controller.pixelProcessesVisible = false

        controller.processManager.dock(controller)
        XCTAssertFalse(controller.processManager.isDetached)
        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertTrue(controller.processesVisible)
        XCTAssertTrue(controller.pixelProcessesVisible)

        controller.processesVisible = false
        controller.processManager.show(controller)
        XCTAssertTrue(controller.processesVisible)
    }

    // MARK: - Apoyo

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func runner() throws -> ProcessRunner {
        let runner = ProcessRunner()
        addTeardownBlock { @MainActor in
            runner.terminateImmediately()
        }
        return runner
    }

    /// Un proyecto temporal abierto, confiable o en solo lectura, con su propio dominio
    /// de preferencias.
    private func workspace(with projects: [CodeProject],
                           trusted: Bool = true) async throws -> (WorkspaceController, URL) {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("Procesos.kzk")
        try Workspace(name: "Procesos", projects: projects).write(to: url)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = WorkspaceController(defaults: defaults)
        if trusted { controller.trust.markTrusted(url) }
        else { controller.confirmTrust = { _ in .readOnly } }
        await controller.openWorkspace(url)
        addTeardownBlock { @MainActor in
            controller.runner.terminateImmediately()
            defaults.removePersistentDomain(forName: suite)
        }
        return (controller, url)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        return predicate()
    }

    private func childProcessID(in output: String) -> pid_t? {
        guard let line = output.components(separatedBy: .newlines).first(where: { $0.hasPrefix("hijo ") }) else {
            return nil
        }
        return pid_t(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
    }

    /// Un socket que escucha en un puerto efímero de 127.0.0.1, para tener un puerto
    /// ocupado por un proceso conocido —este— sin depender de la máquina.
    private func listeningSocket() throws -> (descriptor: Int32, port: Int) {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0, "no se pudo abrir el socket")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, size) }
        }
        XCTAssertEqual(bound, 0, "no se pudo reservar un puerto")
        XCTAssertEqual(Darwin.listen(descriptor, 1), 0)
        var assigned = sockaddr_in()
        var length = size
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        XCTAssertEqual(named, 0)
        return (descriptor, Int(UInt16(bigEndian: assigned.sin_port)))
    }
}
