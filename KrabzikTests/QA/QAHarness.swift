import AppKit
@testable import Krabzik
import SwiftUI
import XCTest

/// Las respuestas que el escenario le da a cada diálogo de la app.
///
/// Un `NSAlert` o un `NSOpenPanel` de verdad cuelgan la corrida —en S1 costó cuatro horas
/// de CI—, así que ningún escenario los deja llegar: acá se decide de antemano qué
/// contesta el usuario, y `QAHarness` lo engancha en los puntos de inyección que la app
/// ya tiene. El registro de QA deja escrito qué se preguntó y qué se respondió, así que
/// una prueba también puede afirmar que **se preguntó**.
@MainActor
final class QADialogScript {
    var trust: TrustDecision = .trust
    var command: CommandDecision = .always
    var chooseWorkspace: URL?
    var createWorkspace: URL?
    var chooseFolders: [URL] = []
    var chooseScripts: [URL] = []
    var createFile: URL?
    var scriptsDirectory: URL?
    var saveCopy: URL?
    var save: SaveDecision = .save
    var discardChanges = true
    var cancelQuery = true
    var stopAgent = true
    var stopProcesses = true
    var saveBeforeSending = true
    /// La guarda de escritura de S8: qué contesta el usuario al «¿Ejecutar N sentencias
    /// que escriben?».
    var confirmWrites = true
    var disconnectWithTransaction = true
    var closeActiveConnections = true
    var discardGridChanges = true

    func install(on controller: WorkspaceController) {
        var dialogs = WorkspaceDialogs()
        dialogs.chooseWorkspace = { [weak self] in self?.chooseWorkspace }
        dialogs.createWorkspace = { [weak self] in self?.createWorkspace }
        dialogs.chooseFolders = { [weak self] in self?.chooseFolders ?? [] }
        dialogs.chooseScripts = { [weak self] in self?.chooseScripts ?? [] }
        dialogs.createFile = { [weak self] _, _ in self?.createFile }
        dialogs.chooseScriptsDirectory = { [weak self] _ in self?.scriptsDirectory }
        dialogs.saveCopy = { [weak self] _, _ in self?.saveCopy }
        dialogs.confirmSave = { [weak self] _ in self?.save ?? .cancel }
        dialogs.confirmDiscardChanges = { [weak self] _ in self?.discardChanges ?? false }
        dialogs.confirmCancelQuery = { [weak self] in self?.cancelQuery ?? false }
        dialogs.confirmStopAgent = { [weak self] in self?.stopAgent ?? false }
        dialogs.confirmStopProcesses = { [weak self] in self?.stopProcesses ?? false }
        dialogs.confirmSaveBeforeSending = { [weak self] _ in self?.saveBeforeSending ?? false }
        controller.session.dialogs = dialogs.logged()
        controller.confirmTrust = { [weak self] _ in self?.trust ?? .cancel }
        controller.projects.confirmCommand = { [weak self] _ in self?.command ?? .cancel }
        controller.workflows.confirmCommand = { [weak self] _ in self?.command ?? .cancel }
        controller.database.askBeforeWriting = { [weak self] _, _, _ in self?.confirmWrites ?? false }
        controller.database.confirmDisconnectWithTransaction = { [weak self] _ in
            self?.disconnectWithTransaction ?? false
        }
        controller.database.confirmCloseActiveConnections = { [weak self] in self?.closeActiveConnections ?? false }
        SQLResultDraft.confirmDiscardChanges = { [weak self] _ in self?.discardGridChanges ?? false }
    }
}

/// El arnés de los escenarios de QA: una app de verdad, con su interfaz montada, sus
/// preferencias aisladas y su registro de eventos encendido.
///
/// Lo que hace distinta a una prueba con arnés de una prueba de unidad: la acción se pide
/// **por el control de la interfaz** (`tap("grid.save")`), no llamando al controlador, y
/// lo que se afirma es la reacción que quedó en el registro. Si alguien deshabilita el
/// botón, le cambia el texto o lo saca de la pantalla, el escenario falla.
@MainActor
final class QAHarness {
    let controller: WorkspaceController
    let defaults: UserDefaults
    let script = QADialogScript()
    /// Carpeta temporal de la corrida: proyectos, scripts y el registro NDJSON.
    let root: URL
    private var window: NSWindow?
    private let suite: String

    init(_ test: XCTestCase, file: StaticString = #filePath, line: UInt = #line) throws {
        suite = "QAHarness." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite) ?? .standard
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("braket-qa-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        controller = WorkspaceController(defaults: defaults)
        script.install(on: controller)
        QAControls.clear()
        QAProbe.activate(writingTo: QAHarness.logPath(for: test))
        let suite = self.suite, root = self.root
        test.addTeardownBlock { @MainActor in
            QAControls.clear()
            QAProbe.deactivate()
            SQLResultDraft.confirmDiscardChanges = { $0.discardAlert().runModal() == .alertFirstButtonReturn }
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Dónde queda la línea de tiempo de este escenario: `.build/qa/logs/<prueba>.ndjson`,
    /// junto al resto de los artefactos de la corrida. `scripts/qa.sh` la nombra en el
    /// informe, así que después de un fallo se puede leer la secuencia completa sin
    /// volver a correr nada.
    static func logPath(for test: XCTestCase) -> String {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let name = test.name.replacingOccurrences(of: "-[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "KrabzikTests.", with: "")
            .replacingOccurrences(of: " ", with: ".")
        return repository.appendingPathComponent(".build/qa/logs/\(name).ndjson").path
    }

    // MARK: - La interfaz

    /// Monta `WorkspaceView` en una ventana real y espera a que SwiftUI evalúe su cuerpo.
    /// Sin esto no hay controles registrados y los `tap(_:)` fallan diciendo justamente eso.
    func mount() async {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: WorkspaceView(controller: controller))
        window.orderFront(nil)
        self.window = window
        QAProbe.mark("harness.mounted")
        await settle(until: { !QAControls.visible.isEmpty })
    }

    func unmount() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    /// Le da tiempo a la app hasta que `condition` se cumple, o hasta el plazo.
    ///
    /// Es asíncrona a propósito. Un `RunLoop.run(until:)` síncrono bombea AppKit pero
    /// **retiene el main actor**, así que las tareas de la app —abrir un proyecto,
    /// guardar un archivo, cualquier `Task { @MainActor }`— no avanzan mientras se
    /// espera, y la espera se agota siempre. Suspender con `Task.sleep` suelta el actor:
    /// corren las tareas y, de paso, el run loop de la ventana reevalúa las vistas.
    @discardableResult
    func settle(until condition: @MainActor () -> Bool = { false }, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            window?.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        } while Date() < deadline
        return condition()
    }

    /// Espera a que exista un evento que coincida con `pattern`.
    @discardableResult
    func settle(forEvent pattern: String, timeout: TimeInterval = 5) async -> Bool {
        await settle(until: { QAProbe.last(pattern) != nil }, timeout: timeout)
    }

    // MARK: - Usar la interfaz

    func control(_ id: String) -> QAControl? { QAControls.control(id) }

    /// Usa el control como lo usaría la persona: comprueba que esté en pantalla y
    /// habilitado, y ejecuta su acción.
    func tap(_ id: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        await settle(until: { QAControls.control(id)?.enabled == true }, timeout: 2)
        do { try QAControls.tap(id) }
        catch {
            XCTFail(((error as? LocalizedError)?.errorDescription ?? "\(error)") + "\n" + timelineText(),
                    file: file, line: line)
            throw error
        }
        await settle(timeout: 0.05)
    }

    /// Comprueba lo que la interfaz está ofreciendo: el texto del control y si deja usarlo.
    func assertControl(_ id: String, title: String? = nil, enabled: Bool? = nil,
                       file: StaticString = #filePath, line: UInt = #line) async {
        await settle(until: { QAControls.control(id) != nil }, timeout: 2)
        guard let control = QAControls.control(id) else {
            XCTFail("falta el control «\(id)» en pantalla. Visibles: " +
                QAControls.visible.map(\.id).sorted().joined(separator: ", "), file: file, line: line)
            return
        }
        if let title { XCTAssertEqual(control.title, title, "título de \(id)", file: file, line: line) }
        if let enabled {
            XCTAssertEqual(control.enabled, enabled,
                           "habilitación de \(id) («\(control.title)»)", file: file, line: line)
        }
    }

    func assertNoControl(_ id: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(QAControls.control(id), "el control «\(id)» no debería estar en pantalla",
                     file: file, line: line)
    }

    func assertScreen(_ name: String, present: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) async {
        await settle(until: { QAControls.screenStack.contains(name) == present }, timeout: 2)
        XCTAssertEqual(QAControls.screenStack.contains(name), present,
                       "pantallas montadas: " + QAControls.screenStack.joined(separator: ", "),
                       file: file, line: line)
    }

    // MARK: - Afirmar la reacción

    func event(_ pattern: String) -> QAEvent? { QAProbe.last(pattern) }

    func events(_ pattern: String) -> [QAEvent] { QAProbe.all(pattern) }

    /// Afirma que pasó algo y, si se piden, con qué datos. Ante un fallo imprime la línea
    /// de tiempo completa: en un escenario de interfaz el valor está en ver la secuencia.
    @discardableResult
    func assertEvent(_ pattern: String, _ fields: [String: String] = [:],
                     file: StaticString = #filePath, line: UInt = #line) async -> QAEvent? {
        await settle(forEvent: pattern, timeout: 3)
        guard let event = QAProbe.last(pattern) else {
            XCTFail("no pasó «\(pattern)».\n" + timelineText(), file: file, line: line)
            return nil
        }
        for (key, expected) in fields {
            XCTAssertEqual(event.fields[key], expected,
                           "\(pattern) · campo \(key)\n" + timelineText(), file: file, line: line)
        }
        return event
    }

    func assertNoEvent(_ pattern: String, file: StaticString = #filePath, line: UInt = #line) {
        if let event = QAProbe.last(pattern) {
            XCTFail("no debería haber pasado «\(pattern)» (seq \(event.seq)).\n" + timelineText(),
                    file: file, line: line)
        }
    }

    /// Afirma el orden: `first` tiene que haber pasado antes que `second`.
    func assertOrder(_ first: String, before second: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        guard let one = QAProbe.all(first).first, let two = QAProbe.all(second).last else {
            XCTFail("faltan «\(first)» o «\(second)».\n" + timelineText(), file: file, line: line)
            return
        }
        XCTAssertLessThan(one.seq, two.seq, "«\(first)» tiene que pasar antes que «\(second)»\n" +
            timelineText(), file: file, line: line)
    }

    func timelineText() -> String {
        "--- línea de tiempo de QA ---\n" + QAProbe.timeline.map(\.line).joined(separator: "\n")
    }

    // MARK: - Material de prueba

    /// Un proyecto en disco, sin pasar por el asistente: es el punto de partida de los
    /// escenarios que no están probando la creación.
    @discardableResult
    func makeProject(name: String = "Demo", folders: [String] = [],
                     connections: [DatabaseConnection] = [],
                     trusted: Bool = true) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var projects: [CodeProject] = []
        for item in folders {
            let directory = folder.appendingPathComponent(item, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            projects.append(CodeProject(name: item, path: item, kind: .files, command: ""))
        }
        var workspace = Workspace(name: name, projects: projects)
        workspace.connections = connections
        let url = folder.appendingPathComponent(name).appendingPathExtension(Workspace.fileExtension)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(workspace).write(to: url)
        if trusted { controller.trust.markTrusted(url) }
        return url
    }

    /// Abre un proyecto y espera a que la interfaz quede en él.
    func openProject(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async {
        await controller.openWorkspace(url)
        await settle(until: { self.controller.workspaceURL != nil }, timeout: 3)
        XCTAssertEqual(controller.workspaceURL?.standardizedFileURL, url.standardizedFileURL,
                       timelineText(), file: file, line: line)
    }

    /// Un script SQL en disco, abierto en una pestaña, con una conexión elegida.
    func openScript(_ text: String, named name: String = "consulta.sql",
                    connection: DatabaseConnection? = nil) async throws -> EditorDocument {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        controller.files.open(url)
        await settle(until: { self.controller.documents.contains { $0.url.standardizedFileURL == url.standardizedFileURL } },
                     timeout: 3)
        let document = try XCTUnwrap(controller.documents.first { $0.url.standardizedFileURL == url.standardizedFileURL })
        controller.selectedDocumentID = document.id
        if let connection { controller.connections.select(connection.id, for: document) }
        await settle(timeout: 0.1)
        return document
    }

    /// Escribe en el documento como lo hace el editor: cambia el texto y lo marca sucio.
    ///
    /// `EditorDocument.isDirty` no se deriva del texto —la vista nativa la enciende al
    /// editar, ver C11—, así que un escenario que solo asignara `text` dejaría el
    /// documento limpio y las preguntas de guardado no aparecerían.
    func type(_ text: String, into document: EditorDocument) {
        document.text = text
        document.isDirty = true
        QAProbe.action("file.edit", ["file": QAField.path(document.url)])
    }

    /// Guarda un perfil de conexión en el catálogo, como lo haría la hoja de conexión.
    @discardableResult
    func addConnection(_ connection: DatabaseConnection) async throws -> DatabaseConnection {
        try await controller.connections.save(connection, password: "")
        return try XCTUnwrap(controller.connections.profiles.first { $0.id == connection.id })
    }
}
