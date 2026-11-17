@testable import Krabzik
import XCTest

/// Suite PRO del catálogo: los procesos de los subproyectos y su puerta de aprobación.
///
/// Lo que se protege acá es el gate de S1: **abrir un proyecto no ejecuta nada**. Un
/// `.kzk` que llega con un comando escrito no lo ejecuta hasta que alguien lo apruebe, y
/// la aprobación se guarda por hash del comando, así que un comando distinto vuelve a
/// preguntar.
///
/// Los procesos son de verdad —`sleep`, lanzado por el mismo `ProcessRunner` que usa la
/// app— y el arnés los mata en el teardown.
@MainActor
final class QAProcessTests: XCTestCase {
    /// PRO-01
    func testStartingOnlyRunsApprovedCommands() async throws {
        let qa = try QAHarness(self)
        qa.script.command = .cancel
        let url = try qa.makeProject(name: "Servidor", folders: ["app"], command: "sleep 30")
        await qa.openProject(url)
        await qa.mount()
        await qa.assertControl("menu.project.start", title: "Iniciar", enabled: true)

        try await qa.tap("menu.project.start")
        await qa.assertEvent("dialog.process.confirmCommand", ["answer": "cancel", "project": "app"])
        await qa.assertEvent("process.start.cancelled", ["project": "app"])
        qa.assertNoEvent("process.start.ok")
        XCTAssertFalse(qa.controller.runner.hasActiveProcesses, "cancelar no ejecuta nada")

        qa.script.command = .always
        try await qa.tap("menu.project.start")
        await qa.assertEvent("process.start.ok", ["project": "app"])
        let running = await qa.settle(until: { qa.controller.runner.hasActiveProcesses })
        XCTAssertTrue(running, "con la aprobación sí arranca\n" + qa.timelineText())
        XCTAssertTrue(qa.controller.processesVisible, "iniciar deja el panel de procesos a la vista")
        qa.controller.runner.terminateImmediately()
    }

    /// PRO-02
    func testTheApprovalIsPerCommandAndEditingItIsTheApproval() async throws {
        let qa = try QAHarness(self)
        qa.script.command = .always
        let url = try qa.makeProject(name: "Servidor", folders: ["app"], command: "sleep 30")
        await qa.openProject(url)
        await qa.mount()
        try await qa.tap("menu.project.start")
        await qa.assertEvent("dialog.process.confirmCommand", ["answer": "always"])
        await qa.settle(until: { qa.controller.runner.hasActiveProcesses })
        qa.controller.stopAll()
        await qa.settle(until: { !qa.controller.runner.hasActiveProcesses }, timeout: 5)

        // El mismo comando ya no pregunta: la aprobación quedó guardada.
        let asked = qa.events("dialog.process.confirmCommand").count
        try await qa.tap("menu.project.start")
        await qa.assertEvent("process.command.approved", ["project": "app", "asked": "false"])
        XCTAssertEqual(qa.events("dialog.process.confirmCommand").count, asked,
                       "un comando ya aprobado no se vuelve a preguntar")
        qa.controller.runner.terminateImmediately()
        await qa.settle(until: { !qa.controller.runner.hasActiveProcesses }, timeout: 5)

        // Editar el comando en la hoja del subproyecto **es** la aprobación: lo escribió
        // el usuario, así que no se le vuelve a preguntar por lo que acaba de escribir.
        var project = try XCTUnwrap(qa.controller.workspace?.projects.first)
        project.command = "sleep 31"
        let saved = await qa.controller.saveSubproject(project)
        XCTAssertTrue(saved)
        try await qa.tap("menu.project.start")
        await qa.assertEvent("process.command.approved", ["asked": "false"])
        XCTAssertEqual(qa.events("dialog.process.confirmCommand").count, asked,
                       "el comando que el usuario escribió queda aprobado al guardarlo")
        qa.controller.runner.terminateImmediately()
        await qa.settle(until: { !qa.controller.runner.hasActiveProcesses }, timeout: 5)

        // Un comando que cambió sin pasar por la hoja —otro editó el .kzk— vuelve a
        // preguntar, porque la aprobación se guarda por hash del comando.
        var workspace = try XCTUnwrap(qa.controller.workspace)
        workspace.projects[0].command = "sleep 32"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(workspace).write(to: url)
        await qa.controller.closeWorkspace()
        await qa.openProject(url)
        try await qa.tap("menu.project.start")
        await qa.assertEvent("dialog.process.confirmCommand", ["command": "sleep 32"])
        XCTAssertGreaterThan(qa.events("dialog.process.confirmCommand").count, asked,
                             "un comando distinto se pregunta de nuevo")
        qa.controller.runner.terminateImmediately()
    }

    /// PRO-03
    func testStoppingEndsEveryProcessAndThePanelShowsIt() async throws {
        let qa = try QAHarness(self)
        qa.script.command = .always
        let url = try qa.makeProject(name: "Servidor", folders: ["uno", "dos"], command: "sleep 30")
        await qa.openProject(url)
        await qa.mount()
        await qa.assertControl("menu.project.stop", title: "Detener", enabled: false)

        try await qa.tap("menu.project.start")
        await qa.settle(until: { qa.controller.runner.runs.values.filter { $0.status.active }.count == 2 }, timeout: 5)
        XCTAssertEqual(qa.controller.runner.runs.values.filter { $0.status.active }.count, 2)
        await qa.assertControl("menu.project.stop", enabled: true)

        try await qa.tap("menu.project.stop")
        await qa.assertEvent("process.stopAll.request", ["active": "true"])
        let stopped = await qa.settle(until: { !qa.controller.runner.hasActiveProcesses }, timeout: 8)
        XCTAssertTrue(stopped, "detener corta todo\n" + qa.timelineText())
        XCTAssertTrue(qa.controller.processesVisible, "el panel inferior queda a la vista")
        await qa.assertControl("menu.project.stop", enabled: false)
    }

    /// ABR-09
    func testLeavingAProjectWithProcessesAsksBeforeStoppingThem() async throws {
        let qa = try QAHarness(self)
        qa.script.command = .always
        qa.script.stopProcesses = false
        let url = try qa.makeProject(name: "Servidor", folders: ["app"], command: "sleep 30")
        await qa.openProject(url)
        await qa.mount()
        try await qa.tap("menu.project.start")
        await qa.settle(until: { qa.controller.runner.hasActiveProcesses }, timeout: 5)

        await qa.controller.closeWorkspace()
        await qa.assertEvent("dialog.process.confirmStop", ["answer": "keep"])
        XCTAssertTrue(qa.controller.runner.hasActiveProcesses, "cancelar no detiene nada")
        XCTAssertEqual(qa.controller.workspaceURL?.standardizedFileURL, url.standardizedFileURL,
                       "y el proyecto sigue abierto")

        qa.script.stopProcesses = true
        await qa.controller.closeWorkspace()
        await qa.assertEvent("dialog.process.confirmStop", ["answer": "stop"])
        await qa.settle(until: { qa.controller.workspace == nil }, timeout: 5)
        XCTAssertNil(qa.controller.workspace)
        let stopped = await qa.settle(until: { !qa.controller.runner.hasActiveProcesses }, timeout: 8)
        XCTAssertTrue(stopped, "al aceptar, los procesos se detienen\n" + qa.timelineText())
    }
}
