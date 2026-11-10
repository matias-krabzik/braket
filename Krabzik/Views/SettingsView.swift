import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let controller: WorkspaceController

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            Group {
                if let workspace = controller.workspace, let url = controller.workspaceURL {
                    ProjectSettingsView(controller: controller, workspace: workspace, url: url).id(url)
                } else {
                    ContentUnavailableView("No hay un proyecto abierto", systemImage: "folder",
                                           description: Text("Abrí un proyecto para editar su configuración."))
                }
            }
            .tabItem { Label("Proyecto", systemImage: "folder") }
        }
        .padding(12)
        .frame(width: 580, height: 620)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private var general: some View {
        Form {
            Section("Apariencia") {
                Picker("Tema", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                Text(settings.theme.detail)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Al iniciar") {
                Toggle("Abrir último estado", isOn: $settings.restoreLastState)
                Text("Recupera el proyecto y las pestañas que dejaste abiertos al salir.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(12)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}
