import Foundation

enum ProjectKind: String, Codable, CaseIterable {
    case laravel = "Laravel", php = "PHP", angular = "Angular", astro = "Astro"
    case node = "Node", files = "Archivos"

    static func detect(at directory: URL) -> (ProjectKind, String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("artisan").path) {
            return (.laravel, "php artisan serve")
        }
        let packageURL = directory.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let dependencies = (json["dependencies"] as? [String: Any] ?? [:])
                .merging(json["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
            let kind: ProjectKind = dependencies["@angular/core"] != nil ? .angular
                : dependencies["astro"] != nil ? .astro : .node
            let scripts = json["scripts"] as? [String: String] ?? [:]
            let script = ["dev", "start", "serve"].first { scripts[$0] != nil }
            let manager = fm.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) ? "pnpm"
                : fm.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) ? "yarn"
                : "npm"
            return (kind, script.map { "\(manager) run \($0)" } ?? "")
        }
        if fm.fileExists(atPath: directory.appendingPathComponent("composer.json").path)
            || fm.fileExists(atPath: directory.appendingPathComponent("index.php").path) {
            return (.php, "php -S 127.0.0.1:8000")
        }
        return (.files, "")
    }
}

struct CodeProject: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var kind: ProjectKind
    var command: String

    func directory(relativeTo workspaceURL: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return workspaceURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }
}

struct Workspace: Codable, Equatable {
    var version = 1
    var name: String
    var projects: [CodeProject] = []
    var connections: [DatabaseConnection] = []
    var scripts: [String] = []

    init(name: String, projects: [CodeProject] = [], connections: [DatabaseConnection] = []) {
        self.name = name; self.projects = projects; self.connections = connections
    }

    private enum CodingKeys: String, CodingKey { case version, name, projects, connections, scripts }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        name = try values.decode(String.self, forKey: .name)
        projects = try values.decodeIfPresent([CodeProject].self, forKey: .projects) ?? []
        connections = try values.decodeIfPresent([DatabaseConnection].self, forKey: .connections) ?? []
        scripts = try values.decodeIfPresent([String].self, forKey: .scripts) ?? []
        scripts = Array(NSOrderedSet(array: scripts)) as? [String] ?? []
    }

    static func read(from url: URL) throws -> Workspace {
        let value = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw WorkspaceError.unsupportedVersion }
        guard Set(value.projects.map(\.id)).count == value.projects.count else {
            throw WorkspaceError.duplicateProject
        }
        guard Set(value.connections.map(\.id)).count == value.connections.count else { throw WorkspaceError.duplicateProject }
        // Nivel lenient: un proyecto existente con una conexión remota sin TLS se
        // abre; el rechazo llega al intentar conectar, con un mensaje accionable.
        for connection in value.connections { _ = try connection.validated(.lenient) }
        return value
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

enum WorkspaceError: LocalizedError {
    case unsupportedVersion, duplicateProject, binaryFile, largeFile, externalChange, missingFolder

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "La versión de este proyecto no es compatible."
        case .duplicateProject: return "El proyecto contiene identificadores duplicados."
        case .binaryFile: return "Este archivo no es texto UTF-8."
        case .largeFile: return "El editor admite archivos de hasta 5 MB en esta versión."
        case .externalChange: return "El archivo cambió en el disco. Guardá una copia para conservar tus cambios."
        case .missingFolder: return "No se encuentra la carpeta del subproyecto."
        }
    }
}

enum Shell {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
