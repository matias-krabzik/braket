import XCTest
import AppKit
@testable import Krabzik

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
        let workspace = Workspace(name: "Tienda", projects: [project])
        try workspace.write(to: url)
        XCTAssertEqual(try Workspace.read(from: url), workspace)
        XCTAssertEqual(project.directory(relativeTo: url), directory.appendingPathComponent("api"))
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
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
        var project = CodeProject(name: "test", path: directory.path, kind: .files, command: "sleep 30 & child=$!; printf 'CHILD:%s\\n' $child; wait")
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
