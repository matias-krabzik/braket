import AppKit
import SwiftUI

struct PHPServiceForm: View {
    @Binding var service: ServiceConfiguration
    let parent: CodeProject
    let workspaceURL: URL
    @State private var interpreters: [String] = []
    @State private var versions: [String: String] = [:]
    @State private var scripts: [String: String] = [:]
    @State private var composerFailure = ""
    private var php: Binding<PHPServiceConfiguration> {
        Binding(get: { service.php ?? PHPServiceConfiguration() }, set: { service.php = $0 })
    }
    private var base: URL { service.executionProject(in: parent).executionDirectory(relativeTo: workspaceURL) }
    var body: some View {
        Section("Tipo de ejecución") {
            Picker("Tipo", selection: Binding(get: { service.php?.kind }, set: { kind in
                if let kind { var value = service.php ?? PHPServiceConfiguration()
                value.kind = kind
                service.php = value }
                else { service.php = nil }
            })) {
                Text("Comando personalizado").tag(Optional<PHPServiceConfiguration.Kind>.none)
                ForEach(PHPServiceConfiguration.Kind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            if service.php != nil {
                Picker("Entorno", selection: php.environment) {
                    ForEach(PHPServiceConfiguration.Environment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.onChange(of: service.php?.environment) { _, value in
                    if value != .local, service.php?.host == "127.0.0.1" { service.php?.host = "0.0.0.0" }
                    if value == .sail, service.php?.containerService == "php" { service.php?.containerService = "laravel.test" }
                }
            }
        }
        if let value = service.php {
            if value.environment == .local {
                Section("Intérprete PHP") {
                    HStack {
                        TextField("Ejecutable PHP", text: php.php)
                        choose("Elegir PHP", key: \.php)
                    }
                    Menu("Instalaciones detectadas") {
                        ForEach(interpreters, id: \.self) { path in
                            Button("PHP \(versions[path] ?? "") · \(path)") { service.php?.php = path } }
                        if interpreters.isEmpty { Text("Elegí el ejecutable PHP de esta Mac") }
                    }.task { await discoverPHP() }
                }
            } else {
                Section(value.environment == .sail ? "Sail" : "Contenedor") {
                    if value.environment == .sail {
                        HStack { TextField("Ejecutable Sail", text: php.sail)
                        choose("Elegir Sail", key: \.sail) }
                    } else {
                        HStack { TextField("Archivo Compose", text: php.composeFile)
                        choose("Elegir archivo Compose", key: \.composeFile) }
                        Toggle("Crear contenedor temporal", isOn: php.useTemporaryContainer)
                    }
                    Toggle("Levantar el servicio del contenedor antes de ejecutar", isOn: php.startContainer)
                    TextField("Servicio del contenedor", text: php.containerService)
                    TextField("Carpeta en el contenedor", text: php.containerDirectory)
                }
            }
            switch value.kind {
            case .script:
                Section("PHP Script") {
                    HStack { TextField("Archivo", text: php.script)
                    choose("Elegir archivo PHP o Artisan", key: \.script) }
                    if URL(fileURLWithPath: value.script).lastPathComponent == "artisan" {
                        HStack {
                            TextField("Comando Artisan", text: php.artisanCommand)
                            Menu("Comandos") {
                                ForEach(["serve", "queue:work", "schedule:work", "list", "migrate", "test"], id: \.self) { command in
                                    Button(command) { service.php?.artisanCommand = command }
                                }
                            }
                        }
                    }
                }
            case .server:
                Section("Servidor") {
                    HStack { TextField("Raíz pública", text: php.documentRoot)
                    choose("Elegir raíz pública", key: \.documentRoot, directory: true) }
                    HStack { TextField("Router opcional", text: php.router)
                    choose("Elegir router", key: \.router) }
                }
            case .composer:
                Section("Composer") {
                    HStack { TextField("Ejecutable Composer", text: php.composer)
                    choose("Elegir Composer", key: \.composer) }
                    HStack { TextField("Archivo", text: php.composerFile)
                    choose("Elegir composer.json", key: \.composerFile) }
                    HStack {
                        TextField("Script", text: php.composerScript)
                        Menu("Scripts") { ForEach(scripts.keys.sorted(), id: \.self) { name in
                            Button(name) { service.php?.composerScript = name } } }
                        Button("Actualizar", systemImage: "arrow.clockwise", action: loadComposer)
                    }
                    if !composerFailure.isEmpty { Text(composerFailure).font(.caption).foregroundStyle(.orange) }
                    if let definition = scripts[value.composerScript] {
                        LabeledContent("Definición de \(value.composerScript)") {
                            Text(definition).font(Theme.codeFont(11)).textSelection(.enabled) }
                    }
                }.task(id: value.composerFile) { loadComposer() }
            }
            if value.servesHTTP {
                Section("Red") {
                    TextField("Host", text: php.host)
                    TextField(value.environment == .local ? "Puerto" : "Puerto interno", value: php.port, format: .number.grouping(.never))
                    if value.environment != .local {
                        TextField("Puerto publicado en la Mac", value: php.publishedPort, format: .number.grouping(.never))
                        Text("Debe coincidir con el puerto publicado en Compose.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Argumentos adicionales") {
                TextField("Uno por línea", text: lines(\.arguments), axis: .vertical).lineLimit(1...4).font(Theme.codeFont(12))
                DisclosureGroup("Opciones del intérprete") {
                    TextField("Opciones PHP · una por línea", text: lines(\.interpreterOptions), axis: .vertical).lineLimit(1...4)
                }
            }
            Section("Vista previa") { Text(value.preview).font(Theme.codeFont(11)).textSelection(.enabled).frame(maxWidth: .infinity,
                                                                                                                 alignment: .leading) }
        }
    }
    private func lines(_ key: WritableKeyPath<PHPServiceConfiguration, [String]>) -> Binding<String> {
        Binding(get: { php.wrappedValue[keyPath: key].joined(separator: "\n") }, set: {
            var value = php.wrappedValue
            value[keyPath: key] = $0.split(separator: "\n").map(String.init)
            php.wrappedValue = value
        })
    }
    private func choose(_ help: String, key: WritableKeyPath<PHPServiceConfiguration, String>, directory: Bool = false) -> some View {
        Button {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = directory
            panel.canChooseFiles = !directory
            panel.directoryURL = base
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let path = url.path.hasPrefix(base.path + "/") ? String(url.path.dropFirst(base.path.count + 1)) : url.path
            var value = php.wrappedValue
            value[keyPath: key] = path
            php.wrappedValue = value
        } label: { Image(systemName: "folder").frame(width: 28, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.fullArea).help(help).accessibilityLabel(help)
    }
    private func discoverPHP() async {
        let manager = FileManager.default
        var paths = ["/opt/homebrew/bin/php", "/usr/local/bin/php", "/usr/bin/php"]
        for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
            for name in (try? manager.contentsOfDirectory(atPath: root)) ?? []
                where name == "php" || name.hasPrefix("php@") { paths.append(root + "/" + name + "/bin/php") }
        }
        interpreters = Array(Set(paths.filter { manager.isExecutableFile(atPath: $0) })).sorted()
        let candidates = interpreters
        versions = await Task.detached {
            var result: [String: String] = [:]
            for path in candidates {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["-n", "-r", "echo PHP_VERSION;"]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do { try process.run()
                process.waitUntilExit()
                    result[path] = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                } catch { continue }
            }
            return result
        }.value
        if service.php?.php == "php", let first = interpreters.first { service.php?.php = first }
    }
    private func loadComposer() {
        do {
            let path = php.wrappedValue.composerFile
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count < 2_000_000 else { throw DatabaseFailure("composer.json es demasiado grande.") }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            scripts = (json?["scripts"] as? [String: Any] ?? [:]).mapValues { value in
                (value as? [String])?.joined(separator: "\n") ?? String(describing: value)
            }
            composerFailure = ""
        } catch { scripts = [:]
        composerFailure = "No se pudo leer composer.json. Revisá la carpeta y el archivo." }
    }
}
