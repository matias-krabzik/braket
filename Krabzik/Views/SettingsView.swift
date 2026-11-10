import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
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
        .frame(width: 480, height: 320)
        .background(Theme.background)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}
