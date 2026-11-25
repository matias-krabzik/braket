import SwiftUI

struct RunConfigurationEditor: View {
    let project: CodeProject
    let active: Bool
    let save: (CodeProject, Bool) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var command: String
    @State private var config: RunConfiguration
    @State private var arguments: String
    @State private var port: String
    @State private var variables: [Variable]
    @State private var failure = ""
    @State private var showsValues = false

    private struct Variable: Identifiable {
        let id = UUID()
        var name = ""
        var value = ""
    }
    init(project: CodeProject, active: Bool, save: @escaping (CodeProject, Bool) -> Bool) {
        self.project = project
        self.active = active
        self.save = save
        let configuration = project.runConfiguration ?? RunConfiguration()
        _command = State(initialValue: project.command)
        _config = State(initialValue: configuration)
        _arguments = State(initialValue: configuration.arguments.joined(separator: "\n"))
        _port = State(initialValue: configuration.expectedPort.map(String.init) ?? "")
        _variables = State(initialValue: configuration.environment.keys.sorted().map {
            Variable(name: $0, value: configuration.environment[$0] ?? "")
        })
    }
    private var valid: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (port.isEmpty || Int(port).map { (1...65535).contains($0) } == true) &&
            Set(variables.map(\.name)).count == variables.count && variables.allSatisfy {
                $0.name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil &&
                    !$0.value.contains("\0")
            } && (config.launchURL.isEmpty || Self.browserURL(config.launchURL) != nil)
    }
    static func browserURL(_ text: String) -> URL? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Configuración de ejecución").font(.headline)
                Spacer()
                Text(project.name).foregroundStyle(.secondary)
            }.padding(20)
            Divider()
            ScrollView {
                Form {
                    TextField("Nombre", text: $config.name)
                    TextField("Comando", text: $command).font(Theme.codeFont(12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Argumentos · uno por línea")
                        TextEditor(text: $arguments).font(Theme.codeFont(12)).frame(height: 65)
                    }
                    TextField("Carpeta de trabajo", text: $config.workingDirectory,
                              prompt: Text("Carpeta del subproyecto; rutas relativas desde ella"))
                    HStack {
                        TextField("Puerto esperado", text: $port).frame(width: 180)
                        TextField("URL", text: $config.launchURL, prompt: Text("http://localhost:3000"))
                    }
                    Section("Variables de entorno") {
                        ForEach($variables) { $variable in
                            HStack {
                                TextField("NOMBRE", text: $variable.name)
                                if showsValues { TextField("Valor", text: $variable.value) }
                                else { SecureField("Valor", text: $variable.value) }
                                Button { variables.removeAll { $0.id == variable.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.fullArea).help("Quitar variable")
                            }
                        }
                        HStack {
                            Button("Agregar variable") { variables.append(Variable()) }
                            Toggle("Mostrar valores", isOn: $showsValues)
                        }
                    }
                    Toggle("Iniciar al abrir el proyecto", isOn: $config.startsAutomatically)
                    Picker("Reinicio automático", selection: $config.restartPolicy) {
                        ForEach(RunConfiguration.RestartPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }.formStyle(.grouped)
            }
            if !failure.isEmpty { Text(failure).foregroundStyle(.red).padding(.horizontal, 20) }
            Divider()
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") { commit(restart: false) }.disabled(!valid)
                if active { Button("Guardar y reiniciar") { commit(restart: true) }.disabled(!valid) }
            }.padding(16).background(Theme.bar)
        }.frame(width: 650, height: 640).background(Theme.background).tint(Theme.accent)
    }
    private func commit(restart: Bool) {
        guard valid else { return }
        config.arguments = arguments.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        config.expectedPort = Int(port)
        config.environment = Dictionary(uniqueKeysWithValues: variables.map { ($0.name, $0.value) })
        var updated = project
        updated.command = command
        updated.runConfiguration = config
        if save(updated, restart) { dismiss() }
        else { failure = "No se pudo guardar. Revisá que el proyecto siga disponible y tenga permiso de escritura." }
    }
}
