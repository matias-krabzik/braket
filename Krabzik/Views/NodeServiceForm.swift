import AppKit
import SwiftUI

struct NodeServiceForm: View {
    @Binding var service: ServiceConfiguration
    let parent: CodeProject
    let workspaceURL: URL
    @State private var installations = NodeInstallations.shared
    @State private var packageScripts: [String: String] = [:]
    @State private var packageFailure = ""
    @State private var readingPackage = false
    private var node: Binding<NodeServiceConfiguration> {
        Binding(get: { service.node ?? NodeServiceConfiguration() }, set: { service.node = $0 })
    }
    private var base: URL { service.executionProject(in: parent).executionDirectory(relativeTo: workspaceURL) }
    var body: some View {
        if let value = service.node {
            Section("Instalaciones Node.js") {
                HStack {
                    if installations.detecting {
                        ProgressView().controlSize(.small)
                        Text("Detectando Node.js y gestores instalados…").foregroundStyle(.secondary)
                    } else if let date = installations.detectedAt {
                        Text("Última detección: \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Actualizar", systemImage: "arrow.clockwise") { Task { await installations.refresh() } }
                        .disabled(installations.detecting).help("Volver a detectar instalaciones en esta Mac")
                }
                if !installations.failure.isEmpty { Text(installations.failure).foregroundStyle(.orange).font(.caption) }
                HStack {
                    TextField("Ejecutable Node.js", text: node.executable).font(Theme.codeFont(12))
                    choose("Elegir Node.js", key: \.executable)
                }
                Menu("Versiones instaladas") {
                    ForEach(installations.installations.filter { $0.tool == "node" }) { item in
                        Button("Node.js \(item.version) · \(item.path)") { service.node?.executable = item.path }
                    }
                    if !installations.installations.contains(where: { $0.tool == "node" }) { Text("Sin instalaciones detectadas") }
                }.disabled(installations.detecting)
            }.task { await installations.loadIfNeeded() }
            if value.kind == .script {
                Section("Node.js") {
                    HStack { TextField("Archivo de entrada", text: node.file)
                    choose("Elegir archivo JavaScript", key: \.file) }
                    TextField("Opciones de Node · una por línea", text: lines(\.runtimeArguments), axis: .vertical).lineLimit(1...4)
                }
            } else {
                Section("Package Script") {
                    HStack { TextField("Archivo", text: node.packageFile)
                    choose("Elegir package.json", key: \.packageFile) }
                    Picker("Gestor", selection: node.manager) {
                        ForEach(NodeServiceConfiguration.Manager.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.onChange(of: service.node?.manager) { _, manager in
                        guard let manager else { return }
                        service.node?.managerExecutable = installations.installations.first { $0.tool == manager.rawValue }?.path ?? manager
                            .rawValue
                    }
                    HStack { TextField("Ejecutable del gestor", text: node.managerExecutable)
                    choose("Elegir gestor", key: \.managerExecutable) }
                    Menu("Gestores instalados") {
                        ForEach(installations.installations.filter { $0.tool == value.manager.rawValue }) { item in
                            Button("\(item.tool) \(item.version) · \(item.path)") { service.node?.managerExecutable = item.path }
                        }
                    }.disabled(installations.detecting)
                    HStack {
                        TextField("Script", text: node.script)
                        Menu("Scripts de package.json") {
                            ForEach(packageScripts.keys.sorted(), id: \.self) { script in Button(script) { service.node?.script = script } }
                        }.disabled(readingPackage || packageScripts.isEmpty)
                    }
                    if readingPackage { ProgressView("Leyendo package.json…").controlSize(.small) }
                    if let definition = packageScripts[value.script] {
                        Text(definition).font(Theme.codeFont(12)).textSelection(.enabled)
                    }
                    if !packageFailure.isEmpty { Text(packageFailure).font(.caption).foregroundStyle(.orange) }
                }.task(id: base.path + "/" + value.packageFile) { await readPackage() }
            }
            Section("Argumentos adicionales") {
                TextField("Uno por línea", text: lines(\.arguments), axis: .vertical).lineLimit(1...4).font(Theme.codeFont(12))
            }
            Section("Vista previa") {
                Text(value.command).font(Theme.codeFont(11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func lines(_ key: WritableKeyPath<NodeServiceConfiguration, [String]>) -> Binding<String> {
        Binding(get: { node.wrappedValue[keyPath: key].joined(separator: "\n") }, set: {
            var value = node.wrappedValue
            value[keyPath: key] = $0.split(separator: "\n").map(String.init)
            node.wrappedValue = value
        })
    }
    private func choose(_ help: String, key: WritableKeyPath<NodeServiceConfiguration, String>) -> some View {
        Button {
            let panel = NSOpenPanel()
            panel.directoryURL = base
            guard panel.runModal() == .OK, let url = panel.url else { return }
            var value = node.wrappedValue
            value[keyPath: key] = key == \.executable || key == \.managerExecutable ? url.path :
                (url.path.hasPrefix(base.path + "/") ? String(url.path.dropFirst(base.path.count + 1)) : url.path)
            node.wrappedValue = value
        } label: { Image(systemName: "folder").frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.fullArea).help(help).accessibilityLabel(help)
    }
    private func readPackage() async {
        readingPackage = true
        let path = node.wrappedValue.packageFile
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        let result = await Task.detached(priority: .utility) { () -> [String: String]? in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_000_000,
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return json["scripts"] as? [String: String] ?? [:]
        }.value
        guard !Task.isCancelled else { return }
        packageScripts = result ?? [:]
        packageFailure = result == nil ? "No se pudo leer package.json. Revisá la carpeta y el archivo." : ""
        readingPackage = false
    }
}
