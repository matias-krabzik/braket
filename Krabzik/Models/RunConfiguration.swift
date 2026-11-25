import Foundation

struct RunConfiguration: Codable, Equatable {
    enum RestartPolicy: String, Codable, CaseIterable {
        case never, onFailure
        var label: String { self == .never ? "Nunca" : "Si falla (máximo 3 intentos)" }
    }
    var shellPath: String?
    var loadShellProfile: Bool?
    var initializeNVM: Bool?
    var preScripts: [String]?
    var stopOnPreScriptFailure: Bool?
    var name = ""
    var arguments: [String] = []
    var workingDirectory = ""
    var environment: [String: String] = [:]
    var expectedPort: Int?
    var launchURL = ""
    var startsAutomatically = false
    var restartPolicy = RestartPolicy.never
}

extension CodeProject {
    var executionName: String {
        guard let name = runConfiguration?.name, !name.isEmpty else { return self.name }
        return name
    }
    var executionCommand: String {
        ([command] + (runConfiguration?.arguments ?? []).map(Shell.quote)).joined(separator: " ")
    }
    var commandApproval: String {
        guard let config = runConfiguration else { return command }
        if serviceDependencyIDs?.isEmpty != false && config.shellPath == nil && config.preScripts?.isEmpty != false && config
            .initializeNVM != true &&
            config.loadShellProfile == nil && config.stopOnPreScriptFailure == nil &&
            config.arguments.isEmpty && config.workingDirectory.isEmpty && config.environment.isEmpty &&
            !config.startsAutomatically && config.restartPolicy == .never { return command }
        let environment = config.environment.keys.sorted().map { "\($0)=\(config.environment[$0] ?? "")" }
        var approval = ([executionCommand, config.workingDirectory] + environment).joined(separator: "\n")
        if let dependencies = serviceDependencyIDs, !dependencies.isEmpty {
            approval += "\nDependencias: " + dependencies.map(\.uuidString).sorted().joined(separator: ",")
        }
        if config.startsAutomatically { approval += "\nInicio automático: true" }
        if config.restartPolicy != .never { approval += "\nReinicio: \(config.restartPolicy.rawValue)" }
        if config.shellPath != nil || config.loadShellProfile != nil {
            approval += "\nShell: \(config.shellPath ?? "/bin/zsh") · perfil: \(config.loadShellProfile ?? true)"
        }
        if config.initializeNVM == true { approval += "\nInicializar nvm" }
        for script in config.preScripts ?? [] { approval += "\nAntes: " + script }
        if config.stopOnPreScriptFailure == false { approval += "\nContinuar si falla un paso previo" }
        return approval
    }
    func executionDirectory(relativeTo url: URL) -> URL {
        guard let path = runConfiguration?.workingDirectory, !path.isEmpty else { return directory(relativeTo: url) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return directory(relativeTo: url).appendingPathComponent(path).standardizedFileURL
    }
}

extension RunConfiguration {
    func validate() throws {
        guard arguments.count <= 256, environment.count <= 256 else {
            throw WorkspaceError.tooManyEntries("argumentos o variables de entorno (256 como máximo)")
        }
        guard (preScripts?.count ?? 0) <= 32,
              shellPath.map({ $0.hasPrefix("/") && $0.count <= 1024 }) != false else {
            throw WorkspaceError.invalidText("el shell o los pasos previos")
        }
        let values = [name, workingDirectory, launchURL, shellPath ?? ""] + arguments + Array(environment.values) + (preScripts ?? [])
        guard values.allSatisfy({ $0.count <= 16_384 && !$0.contains("\0") }),
              environment.keys.allSatisfy({ $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }),
              expectedPort.map({ (1...65535).contains($0) }) != false else {
            throw WorkspaceError.invalidText("la configuración de ejecución")
        }
        if !launchURL.isEmpty {
            guard let url = URL(string: launchURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { throw WorkspaceError.invalidText("la URL de ejecución") }
        }
    }
}
