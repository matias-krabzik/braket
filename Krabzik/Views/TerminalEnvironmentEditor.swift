import SwiftUI

struct TerminalEnvironmentEditor: View {
    let manager: TerminalManager
    let projectURL: URL
    let tab: TerminalTabConfiguration?
    @Environment(\.dismiss) private var dismiss
    @State private var variables: [TerminalEnvironmentVariable]
    @State private var name: String
    @State private var directory: String
    @State private var failure: String?
    init(manager: TerminalManager, projectURL: URL, tab: TerminalTabConfiguration? = nil) {
        self.manager = manager
        self.projectURL = projectURL
        self.tab = tab
        _variables = State(initialValue: tab?.variables ?? manager.configuration(for: projectURL).variables)
        _name = State(initialValue: tab?.name ?? "")
        _directory = State(initialValue: tab?.directory ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tab == nil ? "Entorno compartido del proyecto" : "Configurar terminal").font(.title2.weight(.semibold))
            if tab != nil {
                TextField("Nombre", text: $name)
                TextField("Directorio al iniciar", text: $directory)
            }
            Text(tab == nil ? "Estas variables se heredan en todas las terminales de este proyecto."
                 : "Estas variables sobrescriben las del proyecto solo en esta terminal.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($variables) { $variable in
                        HStack {
                            TextField("NOMBRE", text: $variable.name).frame(width: 170)
                            if variable.secret { SecureField("Valor", text: $variable.value) }
                            else { TextField("Valor", text: $variable.value) }
                            Toggle("Secreta", isOn: $variable.secret).toggleStyle(.checkbox)
                            Button { variables.removeAll { $0.id == variable.id } } label: {
                                Image(systemName: "minus.circle").frame(width: 26, height: 26).contentShape(Rectangle())
                            }.buttonStyle(.fullArea).help("Quitar variable")
                        }
                    }
                }
            }.frame(minHeight: 140)
            Button("Agregar variable", systemImage: "plus") { variables.append(TerminalEnvironmentVariable()) }
            if tab != nil {
                let shared = manager.configuration(for: projectURL).variables.map(\.name).joined(separator: ", ")
                Text("Heredadas del proyecto: \(shared.isEmpty ? "ninguna" : shared)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Sistema → Proyecto → Terminal. Los valores se guardan en el Llavero de esta Mac. "
                 + "Los cambios se aplican al iniciar o reiniciar una sesión.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                if tab != nil {
                    Button("Guardar y reiniciar") { save(restart: true) }
                }
                Button("Guardar") { save(restart: false) }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 680, height: 470).background(Theme.background)
            .preferredColorScheme(Theme.colorScheme)
    }
    private func save(restart: Bool) {
        do {
            var updated = tab
            if tab != nil {
                var isDirectory: ObjCBool = false
                guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
                      directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
                      isDirectory.boolValue else { throw DatabaseFailure("Indicá un nombre y una carpeta absoluta existente.") }
                updated?.name = name
                updated?.directory = directory
            }
            try manager.saveEnvironment(variables, project: projectURL, tab: updated)
            if var updated {
                updated.variables = variables
                manager.updateTab(updated, project: projectURL)
                if restart { Task { await manager.restart(updated, project: projectURL) } }
            }
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
