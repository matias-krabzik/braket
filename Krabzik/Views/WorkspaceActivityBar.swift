import SwiftUI

/// Herramientas del proyecto con la apariencia nativa de la interfaz principal.
struct WorkspaceActivityBar: View {
    let controller: WorkspaceController

    var body: some View {
        VStack(spacing: Theme.zoom(8)) {
            activity("Archivos", id: "explorer.mode.files", icon: "folder",
                     selected: controller.sidebarVisible && !controller.database.browserShowsDatabases) { show(false) }
            activity("Bases de datos", id: "explorer.mode.databases", icon: "cylinder",
                     selected: controller.sidebarVisible && controller.database.browserShowsDatabases) { show(true) }
            activity("Búsqueda · Próximamente", id: "explorer.search", icon: "magnifyingglass", enabled: false) {}
            activity("Git · Próximamente", id: "explorer.git", icon: "arrow.triangle.branch", enabled: false) {}
            Spacer(minLength: 12)
            activity("Resultados SQL", id: "explorer.results", icon: "tablecells",
                     selected: controller.database.resultsVisible && !controller.workflowVisible) {
                if let url = controller.workspaceURL { controller.terminals.setVisible(false, for: url) }
                controller.workflowVisible = false
                if controller.processManager.dockPosition == .bottom && !controller.processManager.isDetached {
                    controller.processesVisible = false
                }
                controller.database.resultsVisible.toggle()
                if controller.database.resultsVisible { controller.outputVisible = false }
            }
            activity("Administrador de procesos", id: "explorer.processes", icon: "waveform.path.ecg",
                     selected: controller.selectedProcessesVisible && !controller.processManager.isDetached) {
                if controller.processManager.isDetached { controller.processManager.detach(controller) }
                else { controller.toggleProcessesPanel() }
            }
            activity("Terminal", id: "explorer.terminal", icon: "terminal", selected: controller.terminals.visible) {
                controller.toggleTerminal()
            }
        }
        .padding(.vertical, Theme.zoom(12)).frame(width: Theme.zoom(38)).background(Theme.bar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel("Herramientas del proyecto")
    }

    private func activity(_ title: String, id: String, icon: String, selected: Bool = false, enabled: Bool = true,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: Theme.zoom(17)))
                .overlay(alignment: .bottomTrailing) {
                    if id == "explorer.processes", controller.runner.hasActiveProcesses {
                        Circle().fill(.green).frame(width: 6, height: 6).offset(x: 3, y: 3)
                    }
                }
                .frame(width: Theme.zoom(30), height: Theme.zoom(30)).contentShape(Rectangle())
        }
        .buttonStyle(ActivityButtonStyle(selected: selected))
        .help(title).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(!enabled || controller.isSwitchingWorkspace)
        .qaControl(id, title: title, enabled: enabled && !controller.isSwitchingWorkspace, action: action)
    }

    private func show(_ databases: Bool) {
        if controller.sidebarVisible && controller.database.browserShowsDatabases == databases {
            controller.sidebarVisible = false
        } else {
            controller.database.browserShowsDatabases = databases
            controller.sidebarVisible = true
        }
        QAProbe.state("state.explorer", ["mode": databases ? "databases" : "files",
                                         "sidebar": QAField.bool(controller.sidebarVisible)])
    }
}

private struct ActivityButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Theme.accent : .secondary)
            .background(Theme.accent.opacity(selected ? 0.12 : (configuration.isPressed ? 0.08 : 0)),
                        in: RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.35)
    }
}
