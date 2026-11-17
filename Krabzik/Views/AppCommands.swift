import SwiftUI

/// Una orden de los menús: qué dice, si se puede usar y qué hace.
///
/// Está separada del menú porque el menú de `KrabzikApp` vive en la `Scene`, que los
/// escenarios de QA no montan —montan `WorkspaceView`—. Con la orden en su propio tipo,
/// el menú la dibuja y la vista la registra como control, así que el título y la
/// habilitación que ve el usuario son exactamente los que afirma la prueba. Si alguien
/// cambia la condición de un `.disabled(...)`, el escenario se entera.
@MainActor
struct AppCommand {
    let id: String
    let title: String
    let enabled: Bool
    let run: () -> Void
}

/// Las órdenes de los menús que un escenario necesita poder usar: archivo nuevo, zoom,
/// paneles, iniciar y detener los procesos.
///
/// No están todas las del menú, solo las que el catálogo de casos ejercita. El resto
/// sigue dibujándose directo en `KrabzikApp`.
@MainActor
struct AppMenuCommands {
    let controller: WorkspaceController

    var newFile: AppCommand {
        AppCommand(id: "menu.file.new", title: "Nuevo archivo",
                   enabled: controller.workspace != nil) { controller.files.create() }
    }

    var toggleSidebar: AppCommand {
        AppCommand(id: "menu.view.sidebar", title: "Mostrar explorador", enabled: true) {
            controller.sidebarVisible.toggle()
            QAProbe.state("state.sidebar", ["visible": QAField.bool(controller.sidebarVisible)])
        }
    }

    var toggleProcesses: AppCommand {
        AppCommand(id: "menu.view.processes", title: "Mostrar panel inferior", enabled: true) {
            controller.toggleProcessesPanel()
            QAProbe.state("state.processesPanel",
                          ["visible": QAField.bool(controller.selectedProcessesVisible),
                           "pixel": QAField.bool(controller.selectedDocument?.pixelArt != nil)])
        }
    }

    var zoomIn: AppCommand {
        AppCommand(id: "menu.view.zoomIn", title: "Aumentar zoom",
                   enabled: controller.settings.uiScale < AppSettings.uiScaleRange.upperBound) {
            controller.settings.zoomIn()
            QAProbe.state("state.zoom", ["scale": QAField.text(String(format: "%.1f", controller.settings.uiScale))])
        }
    }

    var zoomOut: AppCommand {
        AppCommand(id: "menu.view.zoomOut", title: "Reducir zoom",
                   enabled: controller.settings.uiScale > AppSettings.uiScaleRange.lowerBound) {
            controller.settings.zoomOut()
            QAProbe.state("state.zoom", ["scale": QAField.text(String(format: "%.1f", controller.settings.uiScale))])
        }
    }

    var resetZoom: AppCommand {
        AppCommand(id: "menu.view.zoomReset", title: "Restablecer zoom",
                   enabled: controller.settings.uiScale != 1) {
            controller.settings.resetZoom()
            QAProbe.state("state.zoom", ["scale": QAField.text(String(format: "%.1f", controller.settings.uiScale))])
        }
    }

    var startProcesses: AppCommand {
        AppCommand(id: "menu.project.start", title: "Iniciar",
                   enabled: !controller.runnableProjects.isEmpty) { controller.startAll() }
    }

    var stopProcesses: AppCommand {
        AppCommand(id: "menu.project.stop", title: "Detener",
                   enabled: controller.runner.hasActiveProcesses) { controller.stopAll() }
    }

    /// Lo que la vista registra para QA. El orden no importa: se busca por identificador.
    var all: [AppCommand] {
        [newFile, toggleSidebar, toggleProcesses, zoomIn, zoomOut, resetZoom, startProcesses, stopProcesses]
    }
}

/// El botón de menú de una orden: un solo lugar decide el título, la habilitación y la
/// acción.
struct AppCommandButton: View {
    let command: AppCommand

    init(_ command: AppCommand) { self.command = command }

    var body: some View {
        Button(command.title, action: command.run).disabled(!command.enabled)
    }
}
