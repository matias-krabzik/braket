@testable import Krabzik
import XCTest

/// Suite ARC del catálogo: archivos y pestañas del editor.
@MainActor
final class QAFileTests: XCTestCase {
    /// ARC-02
    func testSavingADraftKeepsItsConnectionSelection() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        let connection = try await qa.addConnection(DatabaseConnection(name: "Local"))
        let draft = try qa.controller.docs.createDraft(name: "consulta.sql", text: "SELECT 1;\n")
        qa.controller.connections.select(connection.id, for: draft)
        XCTAssertEqual(qa.controller.connections.selected(for: draft)?.id, connection.id)

        let destination = qa.root.appendingPathComponent("guardada.sql")
        qa.script.scriptsDirectory = qa.root
        qa.script.saveCopy = destination
        let done = await qa.controller.files.save(draft)
        XCTAssertTrue(done)
        await qa.assertEvent("dialog.file.saveCopy", ["answer": "save"])
        let saved = try XCTUnwrap(qa.controller.documents.first { $0.url.standardizedFileURL == destination.standardizedFileURL })
        XCTAssertEqual(qa.controller.connections.selected(for: saved)?.id, connection.id,
                       "la conexión elegida sobrevive a guardar el borrador")
    }

    /// ARC-03
    func testEditingMarksDirtyAndSavingClearsIt() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        let document = try await qa.openScript("SELECT 1;\n", named: "uno.sql")
        XCTAssertFalse(document.isDirty)
        qa.type("SELECT 2;\n", into: document)
        XCTAssertTrue(document.isDirty)
        let done = await qa.controller.files.save(document)
        XCTAssertTrue(done)
        await qa.assertEvent("file.save.ok")
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try String(contentsOf: document.url, encoding: .utf8), "SELECT 2;\n")
    }

    /// ARC-04
    func testClosingADirtyTabAsksAndDiscardKeepsTheFileOnDisk() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        let document = try await qa.openScript("SELECT 1;\n", named: "uno.sql")
        qa.type("SELECT 99;\n", into: document)
        qa.script.save = .discard
        let done = await qa.controller.files.close(document)
        XCTAssertTrue(done)
        await qa.assertEvent("dialog.file.confirmSave", ["answer": "discard"])
        await qa.assertEvent("file.close.ok")
        XCTAssertEqual(try String(contentsOf: document.url, encoding: .utf8), "SELECT 1;\n",
                       "descartar no escribe el archivo")
        XCTAssertFalse(qa.controller.documents.contains { $0.url == document.url })
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// ARC-05
    func testRenamingAScriptCarriesItsConnection() async throws {
        let qa = try QAHarness(self)
        let projectURL = try qa.makeProject(name: "Tienda")
        await qa.openProject(projectURL)
        let connection = try await qa.addConnection(DatabaseConnection(name: "Local"))
        let document = try await qa.openScript("SELECT 1;\n", named: "vieja.sql", connection: connection)
        let destination = document.url.deletingLastPathComponent().appendingPathComponent("nueva.sql")
        qa.controller.connections.relocateScript(from: document.url, to: destination)
        try FileManager.default.moveItem(at: document.url, to: destination)
        qa.controller.docs.relocate(from: document.url, to: destination)
        let moved = try XCTUnwrap(qa.controller.documents.first { $0.url.standardizedFileURL == destination.standardizedFileURL })
        XCTAssertEqual(qa.controller.connections.selected(for: moved)?.id, connection.id)
    }

    /// ARC-06
    func testClosingTabsInBulkLeavesTheRightOnesOpen() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        for name in ["a.sql", "b.sql", "c.sql"] { _ = try await qa.openScript("SELECT 1;\n", named: name) }
        XCTAssertEqual(qa.controller.documents.count, 3)
        let tabs = qa.controller.documents
        qa.controller.closeTabs(Array(tabs.dropFirst(2)))
        await qa.settle(until: { qa.controller.documents.count == 2 })
        XCTAssertEqual(qa.controller.documents.map { $0.url.lastPathComponent }, ["a.sql", "b.sql"])
        qa.controller.closeTabs(qa.controller.documents)
        await qa.settle(until: { qa.controller.documents.isEmpty })
        XCTAssertTrue(qa.controller.documents.isEmpty)
    }

    /// ARC-07
    func testMovingATabChangesTheOrder() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Tienda")
        await qa.openProject(url)
        for name in ["a.sql", "b.sql"] { _ = try await qa.openScript("SELECT 1;\n", named: name) }
        let names = qa.controller.documents.map { $0.url.lastPathComponent }
        XCTAssertEqual(names, ["a.sql", "b.sql"])
        let second = try XCTUnwrap(qa.controller.documents.last).id
        let first = try XCTUnwrap(qa.controller.documents.first).id
        qa.controller.moveTab(second, before: first)
        XCTAssertEqual(qa.controller.documents.map { $0.url.lastPathComponent }, ["b.sql", "a.sql"])
    }

    /// ARC-09
    func testReadOnlyProjectsRefuseToCreateOrRename() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Ajeno", trusted: false)
        qa.script.trust = .readOnly
        await qa.openProject(url)
        XCTAssertTrue(qa.controller.isReadOnly)
        qa.controller.files.create()
        XCTAssertNil(qa.controller.newFileRequest, "en solo lectura no se pide un archivo nuevo")
        XCTAssertNil(qa.controller.files.rename(url), "en solo lectura no se renombra nada")
    }

    /// ABR-08
    func testLeavingWithUnsavedWorkAsksAndCancelKeepsEverything() async throws {
        let qa = try QAHarness(self)
        let first = try qa.makeProject(name: "Uno")
        await qa.openProject(first)
        let document = try await qa.openScript("SELECT 1;\n", named: "uno.sql")
        qa.type("SELECT 2;\n", into: document)
        qa.script.save = .cancel
        let allowed = await qa.controller.prepareToLeave()
        await qa.assertEvent("dialog.file.confirmSave", ["answer": "cancel"])
        XCTAssertFalse(allowed, "cancelar en el diálogo no deja irse")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(qa.controller.workspaceURL?.standardizedFileURL, first.standardizedFileURL)
    }
}
