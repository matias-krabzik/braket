import AppKit
@testable import Krabzik
import XCTest

final class CoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("krabzik-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWorkspaceRoundTripAndRelativePaths() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("Tienda.krabzik")
        let project = CodeProject(name: "API", path: "api", kind: .laravel, command: "php artisan serve")
        var workspace = Workspace(name: "Tienda", projects: [project], connections: [DatabaseConnection()])
        workspace.scripts = ["sql/consultas.sql", "sql/migracion.sql"]
        try workspace.write(to: url)
        XCTAssertEqual(try Workspace.read(from: url), workspace)
        XCTAssertEqual(project.directory(relativeTo: url), directory.appendingPathComponent("api"))
    }

    // MARK: - Rendimiento del editor (C11)

    /// Un archivo cerca del límite de 5 MB, hecho de líneas de código repetidas.
    private func largeSource() -> String {
        let line = "    let value = compute(index: 42, label: \"etiqueta\")  // comentario\n"
        let limit = 5 * 1024 * 1024
        var text = ""
        text.reserveCapacity(limit)
        while text.utf8.count + line.utf8.count <= limit { text += line }
        return text
    }

    /// La latencia de tecla no puede depender del tamaño del archivo.
    ///
    /// Medido sobre 5 MB y 76.000 líneas, insertando al principio, en esta misma
    /// configuración de pruebas:
    ///
    /// | | ms/tecla |
    /// |---|---|
    /// | antes de C11 | 8,39 |
    /// | `LineIndex.replace`, sola, antes | 7,25 |
    /// | leer `textView.string`, lo que señalaba el spec | 0,27 |
    /// | `NSTextView` sin delegado: el piso de TextKit | 0,06 |
    /// | después de C11 | **0,83** |
    @MainActor func testEditorKeystrokeLatencyOnLargeDocument() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("grande.swift")
        let data = Data(largeSource().utf8)
        try data.write(to: url)
        let document = try EditorDocument(url: url, data: data)
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        defer { document.releaseEditor() }
        XCTAssertGreaterThan(surface.lines.count, 50_000, "el archivo tiene que ser grande de verdad")

        // Insertar al principio es el peor caso: desplaza todas las líneas siguientes.
        let keystrokes = 200
        let start = DispatchTime.now()
        for _ in 0 ..< keystrokes {
            surface.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let perKeystroke = elapsed / Double(keystrokes)
        // Un frame a 120 Hz. Si CI resulta demasiado variable, el umbral se sube acá y se
        // anota por qué; lo que no se puede volver es a reconstruir el índice por tecla.
        XCTAssertLessThan(perKeystroke, 8,
                          "\(String(format: "%.2f", perKeystroke)) ms por pulsación sobre \(data.count / 1024) KiB")
        // Y el índice sigue siendo exacto después de 200 ediciones.
        XCTAssertEqual(surface.lines.starts, LineIndex(surface.textView.string).starts)
    }

    /// Criterio 2 de C11: el texto que ve el resto de la app es exactamente el del editor,
    /// aunque no se haya leído en cada tecla.
    @MainActor func testDocumentTextReflectsEditorAfterEditing() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("edit.swift")
        let data = Data("let a = 1\n".utf8)
        try data.write(to: url)
        let document = try EditorDocument(url: url, data: data)
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        defer { document.releaseEditor() }

        surface.textView.insertText("// hola\n", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(document.text, "// hola\nlet a = 1\n")
        XCTAssertEqual(document.text, surface.textView.string)
        XCTAssertTrue(document.isDirty)

        // Soltar la vista no pierde lo escrito.
        document.releaseEditor()
        XCTAssertEqual(document.text, "// hola\nlet a = 1\n")
    }

    /// Un documento abierto y nunca mostrado no tiene surface de donde releer: devuelve el
    /// contenido con el que se abrió.
    @MainActor func testDocumentTextWithoutSurfaceReturnsInitialContent() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("sin-vista.sql")
        let data = Data("SELECT 1;\n".utf8)
        try data.write(to: url)
        let document = try EditorDocument(url: url, data: data)
        XCTAssertNil(document.editorStorage)
        XCTAssertEqual(document.text, "SELECT 1;\n")
        document.markTextStale()
        XCTAssertEqual(document.text, "SELECT 1;\n", "sin vista, la caché es exacta")
    }

    // MARK: - Credenciales ligadas al extremo (C4)

    /// El predicado que decide si la credencial del perfil anterior quedó huérfana.
    /// Estaba escrito como una condición de tres líneas dentro de `saveConnection`, donde
    /// la insensibilidad a mayúsculas del host no se veía.
    @MainActor func testEndpointChangeDetection() {
        var base = DatabaseConnection()
        base.host = "Db.Example.COM"
        base.port = 3306
        base.username = "krabzik"
        base.tls = .verified

        func cambiando(_ ajuste: (inout DatabaseConnection) -> Void) -> Bool {
            var otra = base
            ajuste(&otra)
            return WorkspaceController.endpointChanged(from: base, to: otra)
        }

        XCTAssertFalse(cambiando { _ in }, "el mismo perfil no cambia nada")
        XCTAssertFalse(cambiando { $0.host = "db.example.com" }, "el host no distingue mayúsculas")
        XCTAssertFalse(cambiando { $0.name = "otro nombre" }, "el nombre no es parte del extremo")
        XCTAssertFalse(cambiando { $0.database = "otra_base" }, "la base tampoco")
        XCTAssertTrue(cambiando { $0.host = "otro.example.com" })
        XCTAssertTrue(cambiando { $0.port = 3307 })
        XCTAssertTrue(cambiando { $0.username = "otro" })
        XCTAssertTrue(cambiando { $0.tls = .disabled })
    }

    // MARK: - Contrato del formato (C7)

    /// Escribe el `.krabzik` tal cual, sin pasar por `Workspace.write`: estas pruebas
    /// simulan un archivo ajeno, que no tiene por qué cumplir el formato.
    private func writeRaw(_ json: String, to url: URL) throws {
        try Data(json.utf8).write(to: url)
    }

    private static func archivoConRuta(_ path: String) -> String {
        #"{"version":1,"name":"T","projects":[{"id":"\#(UUID().uuidString)","name":"api","#
            + #""path":"\#(path)","kind":"Archivos","command":""}]}"#
    }

    private static func archivoConComando(_ command: String) -> String {
        #"{"version":1,"name":"C","projects":[{"id":"\#(UUID().uuidString)","name":"api","#
            + #""path":"a","kind":"Archivos","command":"\#(command)"}]}"#
    }

    private func message(of error: Error) -> String {
        (error as? WorkspaceError)?.errorDescription ?? String(describing: error)
    }

    func testWorkspaceRejectsOversizedCollections() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("grande.krabzik")
        let scripts = (0 ..< 1_000).map { "\"sql/\($0).sql\"" }.joined(separator: ",")
        try writeRaw(#"{"version":1,"name":"Grande","scripts":[\#(scripts)]}"#, to: url)
        XCTAssertThrowsError(try Workspace.read(from: url)) { error in
            XCTAssertEqual(self.message(of: error),
                           "El proyecto declara demasiados scripts SQL (512 como máximo, el archivo trae 1000).")
        }

        let projects = (0 ..< 70).map {
            #"{"id":"\#(UUID().uuidString)","name":"p\#($0)","path":"p\#($0)","kind":"Archivos","command":""}"#
        }.joined(separator: ",")
        try writeRaw(#"{"version":1,"name":"Grande","projects":[\#(projects)]}"#, to: url)
        XCTAssertThrowsError(try Workspace.read(from: url)) { error in
            XCTAssertEqual(self.message(of: error),
                           "El proyecto declara demasiados subproyectos (64 como máximo, el archivo trae 70).")
        }
    }

    func testWorkspaceRejectsEscapingRelativePaths() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("fuga.krabzik")
        let project = #"{"id":"\#(UUID().uuidString)","name":"api","path":"../../etc","kind":"Archivos","command":""}"#
        try writeRaw(#"{"version":1,"name":"Fuga","projects":[\#(project)]}"#, to: url)
        XCTAssertThrowsError(try Workspace.read(from: url)) { error in
            XCTAssertEqual(self.message(of: error),
                           "La ruta «../../etc», de «api» sale del directorio del proyecto.")
        }

        // Una ruta absoluta sí se admite: S1 la clasifica como externa y la trata aparte.
        let externo = #"{"id":"\#(UUID().uuidString)","name":"api","path":"/tmp","kind":"Archivos","command":""}"#
        try writeRaw(#"{"version":1,"name":"Fuga","projects":[\#(externo)]}"#, to: url)
        XCTAssertEqual(try Workspace.read(from: url).projects.first?.path, "/tmp")
    }

    func testWorkspaceRejectsControlAndBidiText() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("bidi.krabzik")
        for (campo, json) in [
            ("el nombre del proyecto", #"{"version":1,"name":"Tienda\u202Ejs.exe"}"#),
            ("la ruta de «api»", Self.archivoConRuta(#"a\u0000b"#))
        ] {
            try writeRaw(json, to: url)
            XCTAssertThrowsError(try Workspace.read(from: url)) { error in
                XCTAssertTrue(self.message(of: error).hasPrefix("El proyecto contiene texto no válido en"),
                              "para \(campo) dijo: \(self.message(of: error))")
            }
        }
    }

    func testWorkspaceBoundsCommandLengthButAllowsNewlines() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("comando.krabzik")
        try writeRaw(Self.archivoConComando(String(repeating: "x", count: 10_000)), to: url)
        XCTAssertThrowsError(try Workspace.read(from: url)) { error in
            XCTAssertEqual(self.message(of: error),
                           "Es demasiado largo el comando de «api» (4000 caracteres como máximo, el archivo trae 10000).")
        }

        // Un comando multilínea es legítimo.
        let multilinea = String(repeating: "echo hola\\n", count: 300)
        try writeRaw(Self.archivoConComando(multilinea), to: url)
        let leido = try Workspace.read(from: url)
        XCTAssertEqual(leido.projects.first?.command.filter { $0 == "\n" }.count, 300)
    }

    func testWorkspaceNormalizesAndDeduplicatesScripts() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("scripts.krabzik")
        try writeRaw(#"{"version":1,"name":"S","scripts":["sql/a.sql","./sql/a.sql","sql/./b.sql","sql/sub/../b.sql"]}"#,
                     to: url)
        XCTAssertEqual(try Workspace.read(from: url).scripts, ["sql/a.sql", "sql/b.sql"])
    }

    func testHostileFixtureIsRejected() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hostil.krabzik")
        XCTAssertNoThrow(try Data(contentsOf: fixture), "el fixture tiene que existir en el árbol")
        XCTAssertThrowsError(try Workspace.read(from: fixture)) { error in
            XCTAssertTrue(self.message(of: error).hasPrefix("El proyecto contiene texto no válido en"),
                          "dijo: \(self.message(of: error))")
        }
    }

    func testWorkspaceRejectsFutureVersionAndDuplicateIDs() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("test.krabzik")
        var workspace = Workspace(name: "Future")
        workspace.version = 99
        try workspace.write(to: url)
        XCTAssertThrowsError(try Workspace.read(from: url))
        workspace.version = 1
        let project = CodeProject(name: "A", path: "a", kind: .files, command: "")
        workspace.projects = [project, project]
        try workspace.write(to: url)
        XCTAssertThrowsError(try Workspace.read(from: url))
    }

    func testDetectsFrameworksAndActualScripts() throws {
        let directory = try temporaryDirectory()
        let manifest = directory.appendingPathComponent("package.json")
        let cases: [(String, ProjectKind, String)] = [
            (#"{"dependencies":{"@angular/core":"*"},"scripts":{"start":"ng serve"}}"#, .angular, "npm run start"),
            (#"{"devDependencies":{"astro":"*"},"scripts":{"dev":"astro dev"}}"#, .astro, "npm run dev"),
            (#"{"scripts":{"dev":"node server.js"}}"#, .node, "npm run dev"),
            (#"{"name":"library"}"#, .node, "")
        ]
        for (json, kind, command) in cases {
            try Data(json.utf8).write(to: manifest)
            let result = ProjectKind.detect(at: directory)
            XCTAssertEqual(result.0, kind)
            XCTAssertEqual(result.1, command)
        }
        try Data().write(to: directory.appendingPathComponent("artisan"))
        XCTAssertEqual(ProjectKind.detect(at: directory).0, .laravel)
    }

    func testSaveDoesNotOverwriteExternalChangesOrDeletedFile() throws {
        let url = try temporaryDirectory().appendingPathComponent("example.php")
        let original = Data("original".utf8)
        try original.write(to: url)
        try DocumentIO.save(Data("edit".utf8), to: url, expected: original)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "edit")
        try Data("external".utf8).write(to: url)
        XCTAssertThrowsError(try DocumentIO.save(original, to: url, expected: Data("edit".utf8)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try DocumentIO.save(original, to: url, expected: original))
    }

    func testIncrementalLineIndexMatchesFullRebuildWithUnicode() {
        var text = "uno\n🦀 dos\ntres\n"
        var index = LineIndex(text)
        let edits: [(NSRange, String)] = [
            (NSRange(location: 4, length: 0), "\n"),
            (NSRange(location: 0, length: 4), "inicio\n"),
            (NSRange(location: 8, length: 2), "ab\ncd"),
            (NSRange(location: 0, length: 0), "á\n")
        ]
        for (range, replacement) in edits {
            index.replace(range, with: replacement)
            text = (text as NSString).replacingCharacters(in: range, with: replacement)
            XCTAssertEqual(index.starts, LineIndex(text).starts)
            for position in 0...text.utf16.count {
                XCTAssertEqual(index.line(at: position), LineIndex(text).line(at: position))
            }
        }
    }

    func testUTF8OutputAcrossAllPossibleChunkBoundaries() {
        let expected = "Conexión lista 🦀 — 日本語\n"
        let data = Data(expected.utf8)
        for boundary in 0...data.count {
            var decoder = UTF8StreamDecoder()
            let result = decoder.decode(data.prefix(boundary)) + decoder.decode(data.suffix(data.count - boundary))
            XCTAssertEqual(result, expected)
        }
    }

    @MainActor func testRejectsBinaryDocuments() async throws {
        let url = try temporaryDirectory().appendingPathComponent("binary")
        XCTAssertThrowsError(try EditorDocument(url: url, data: Data([0, 1, 2])))
    }

    @MainActor func testEditorHasVisibleTextGeometry() async throws {
        let url = try temporaryDirectory().appendingPathComponent("example.php")
        let document = try EditorDocument(url: url, data: Data("<?php\n\nreturn 42;\n".utf8))
        let surface = EditorSurface(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.contentView = surface
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 200_000_000)
        surface.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(surface.textView.frame.height, 50)
        XCTAssertGreaterThan(surface.textView.visibleRect.width, 100)
        XCTAssertLessThan(surface.textView.frame.width, 2000)
        XCTAssertNotNil(surface.textView.textLayoutManager)
        XCTAssertTrue(surface.scrollView.verticalRulerView?.clipsToBounds == true)
    }

    @MainActor func testEditorSurfaceTeardownIsIdempotentAndStopsObserving() async throws {
        let url = try temporaryDirectory().appendingPathComponent("example.php")
        let document = try EditorDocument(url: url, data: Data("<?php\n\nreturn 42;\n".utf8))
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        XCTAssertTrue(surface.isObservingScroll)
        surface.teardown()
        XCTAssertFalse(surface.isObservingScroll)
        surface.teardown()
        XCTAssertFalse(surface.isObservingScroll, "teardown() tiene que ser idempotente")
        // Una notificación posterior no debe programar resaltado ni fallar.
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: surface.scrollView.contentView)
        XCTAssertFalse(surface.isObservingScroll)
    }

    @MainActor func testClosingDocumentReleasesItsEditorSurface() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("example.php")
        try Data("<?php\n".utf8).write(to: url)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "krabzik-editor-\(UUID())"))
        let controller = WorkspaceController(defaults: defaults)
        let document = try EditorDocument(url: url, data: Data(contentsOf: url))
        let surface = EditorSurface(document: document)
        document.editorStorage = surface
        controller.documents = [document]
        controller.selectedDocumentID = document.id
        XCTAssertTrue(surface.isObservingScroll)
        controller.closeDocument(document)
        for _ in 0..<100 where !controller.documents.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(controller.documents.isEmpty)
        XCTAssertFalse(surface.isObservingScroll, "cerrar la pestaña tiene que soltar la vista nativa")
        XCTAssertNil(document.editorStorage)
    }

    @MainActor func testProcessCapturesOutputExitCodeAndQuotedWorkingDirectory() async throws {
        let directory = try temporaryDirectory().appendingPathComponent("folder with ' quote")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = CodeProject(name: "test", path: directory.path, kind: .files, command: "printf 'á 🦀'; pwd; exit 7")
        let runner = ProcessRunner()
        runner.start(project, workspaceURL: directory.appendingPathComponent("test.krabzik"))
        let run = runner.state(for: project.id)
        for _ in 0..<100 where run.status.active { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(run.status, .exited(7))
        XCTAssertTrue(run.output.contains("á 🦀"))
        XCTAssertTrue(run.output.contains(directory.path))
        runner.terminateImmediately()
    }

    @MainActor func testStopTerminatesDescendantsAndAllowsRestart() async throws {
        let directory = try temporaryDirectory()
        var project = CodeProject(name: "test", path: directory.path, kind: .files,
                                  command: "sleep 30 & child=$!; printf 'CHILD:%s\\n' $child; wait")
        let runner = ProcessRunner()
        defer { runner.terminateImmediately() }
        runner.start(project, workspaceURL: directory.appendingPathComponent("test.krabzik"))
        let run = runner.state(for: project.id)
        for _ in 0..<100 where !run.output.contains("\nCHILD:") { try await Task.sleep(nanoseconds: 50_000_000) }
        let childLine = run.output.components(separatedBy: "\n").first { $0.hasPrefix("CHILD:") }
        let childPID = childLine.flatMap { Int32($0.dropFirst(6)) }
        XCTAssertNotNil(childPID)
        runner.stop(project.id)
        for _ in 0..<100 where run.status.active { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(run.status, .idle)
        if let childPID { XCTAssertEqual(kill(childPID, 0), -1) }
        project.command = "printf restarted"
        runner.start(project, workspaceURL: directory.appendingPathComponent("test.krabzik"))
        for _ in 0..<100 where run.status.active { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(run.status, .exited(0))
        XCTAssertTrue(run.output.contains("restarted"))
    }
}
