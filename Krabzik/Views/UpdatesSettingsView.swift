import SwiftUI

struct UpdatesSettingsView: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section("Braket") {
                LabeledContent("Versión", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("Canal", value: "Estable")
                Toggle("Buscar actualizaciones automáticamente", isOn: $updater.automaticallyChecks)
                Text("Te avisaremos cuando haya una nueva versión. Vos elegís cuándo instalarla y reiniciar.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                if let date = updater.lastCheck {
                    LabeledContent("Última comprobación") { Text(date, format: .dateTime.day().month().hour().minute()) }
                }
                Button("Buscar actualizaciones…", action: updater.check).disabled(!updater.canCheck)
                Text("Las actualizaciones se descargan desde krabzik.com y se verifican antes de instalarse.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden).padding(12)
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        Button("Buscar actualizaciones…", action: updater.check).disabled(!updater.canCheck)
    }
}
