@testable import Krabzik
import XCTest

@MainActor
final class QAActivityBarTests: XCTestCase {
    func testActiveToolHidesAndReopensExplorerWithoutClosingDocument() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Sidebar", folders: ["app"])
        await qa.openProject(url)
        let document = try await qa.openScript("SELECT 1;\n")
        await qa.mount()

        try await qa.tap("explorer.mode.files")
        await qa.assertScreen("explorer.files", present: false)
        XCTAssertFalse(qa.controller.sidebarVisible)
        XCTAssertEqual(qa.controller.selectedDocumentID, document.id)

        try await qa.tap("explorer.mode.files")
        await qa.assertScreen("explorer.files")
        try await qa.tap("explorer.mode.databases")
        await qa.assertScreen("explorer.databases")
        try await qa.tap("explorer.mode.databases")
        await qa.assertScreen("explorer.databases", present: false)
        XCTAssertFalse(qa.controller.sidebarVisible)
        try await qa.tap("explorer.mode.files")
        await qa.assertScreen("explorer.files")
        XCTAssertEqual(qa.controller.selectedDocumentID, document.id)
        XCTAssertEqual(qa.controller.workspaceURL, url)
    }

    func testReservedToolsAndProcessesNavigation() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Herramientas")
        await qa.openProject(url)
        await qa.mount()
        await qa.assertControl("explorer.search", title: "Búsqueda · Próximamente", enabled: false)
        await qa.assertControl("explorer.git", title: "Git · Próximamente", enabled: false)

        try await qa.tap("explorer.processes")
        XCTAssertFalse(qa.controller.selectedProcessesVisible)
        try await qa.tap("explorer.processes")
        XCTAssertTrue(qa.controller.selectedProcessesVisible)
        XCTAssertEqual(qa.controller.workspaceURL, url)
    }

    func testResultsRemainAvailableAfterOpeningProcesses() async throws {
        let qa = try QAHarness(self)
        let url = try qa.makeProject(name: "Resultados")
        await qa.openProject(url)
        let document = try await qa.openScript("SELECT 1;\n")
        let result = SQLResult(statement: 1, line: 1)
        document.sqlExecution.results.append(result)
        document.sqlExecution.selectedResultID = result.id
        await qa.mount()

        try await qa.tap("explorer.results")
        XCTAssertTrue(qa.controller.database.resultsVisible)
        try await qa.tap("explorer.processes")
        XCTAssertFalse(qa.controller.database.resultsVisible)
        try await qa.tap("explorer.results")
        XCTAssertTrue(qa.controller.database.resultsVisible)
        XCTAssertEqual(document.sqlExecution.selectedResult?.id, result.id)
    }
}
