import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// El tipo de documento del proyecto, declarado en Info.plist. Lo usan los paneles de
    /// abrir y guardar.
    static let krabzikProject = UTType(exportedAs: "com.krabzik.project", conformingTo: .json)
}

/// Qué clase de subproyecto es, y con eso el comando que se propone al agregarlo.
/// `detect(at:)` mira el disco: no es un dato que el usuario tenga que elegir.
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

/// Dónde queda una ruta del `.krabzik` respecto del propio archivo. Las externas no
/// se rechazan —los proyectos legítimos del usuario suelen tener carpetas afuera—
/// pero no se confía en ellas hasta que el usuario las vea.
enum PathScope: Equatable {
    case internalToProject
    case external
}

/// Clasifica una ruta relativa o absoluta respecto del directorio del `.krabzik`.
/// Resuelve symlinks: uno que apunta afuera cuenta como externo.
func pathScope(_ path: String, relativeTo workspaceURL: URL) -> PathScope {
    let base = workspaceURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path)
                                      : base.appendingPathComponent(path))
        .resolvingSymlinksInPath().standardizedFileURL
    if target.path == base.path { return .internalToProject }
    return target.path.hasPrefix(base.path + "/") ? .internalToProject : .external
}

/// Topes del formato `.krabzik`. Son holgados respecto del uso real —el proyecto de
/// ejemplo tiene tres subproyectos— y están para que un archivo ajeno no pueda degradar
/// la interfaz. Si aparece un caso legítimo que los supera se sube el número; no se quita
/// la comprobación. Ver docs/specs/C7-validacion-formato-krabzik.md.
enum WorkspaceLimits {
    static let projects = 64
    static let connections = 32
    static let scripts = 512
    static let nameLength = 200
    static let pathLength = 1_024
    static let commandLength = 4_000
}

extension String {
    /// Texto admisible en un `.krabzik`. Acá se **rechaza** en vez de sanear: un archivo
    /// con un override bidi en el nombre de un subproyecto miente sobre lo que dice, y el
    /// diálogo de confianza de S1 muestra justamente esos campos. Para lo que viene del
    /// modelo, que no se puede rechazar, está `ModelText`.
    func isValidProjectText(newlines: Bool = false) -> Bool {
        for scalar in unicodeScalars {
            if scalar == "\t" { continue }
            if newlines, scalar == "\n" || scalar == "\r" { continue }
            switch scalar.value {
            case 0x00 ... 0x1F, 0x7F,       // controles
                 0x200B ... 0x200F,         // zero-width y marcas de dirección
                 0x202A ... 0x202E,         // overrides bidi
                 0x2066 ... 0x2069,         // aislantes bidi
                 0xFEFF:                    // BOM en medio del texto
                return false
            default: continue
            }
        }
        return true
    }
}

/// Un subproyecto dentro del `.krabzik`: una carpeta y, opcionalmente, un comando.
///
/// `path` puede ser relativo al `.krabzik` o absoluto. Un relativo que salga de la
/// carpeta se rechaza al leer (C7); un absoluto se admite y queda clasificado como
/// externo, que es lo que el modelo de confianza mira antes de montarlo (S1).
struct CodeProject: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var path: String
    var kind: ProjectKind
    var command: String

    func scope(relativeTo workspaceURL: URL) -> PathScope {
        pathScope(path, relativeTo: workspaceURL)
    }

    /// Nombre acotado para los mensajes de error: el del archivo puede ser larguísimo
    /// y el mensaje tiene que seguir siendo legible.
    var shortName: String { name.count > 40 ? String(name.prefix(40)) + "…" : name }

    func directory(relativeTo workspaceURL: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return workspaceURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }
}

/// El contenido de un archivo `.krabzik`: nombre, subproyectos, conexiones y scripts.
///
/// Es un formato de entrada de terceros —se puede recibir por mail o clonar— así que
/// `read(from:)` tiene contrato: topes, texto admisible y rutas que no salgan de la
/// carpeta. Las contraseñas nunca se serializan acá.
struct Workspace: Codable, Equatable {
    var version = 1
    var name: String
    var projects: [CodeProject] = []
    var connections: [DatabaseConnection] = []
    var scripts: [String] = []
    var iconStyle = ProjectIconStyle()

    init(name: String, projects: [CodeProject] = [], connections: [DatabaseConnection] = []) {
        self.name = name
        self.projects = projects
        self.connections = connections
    }

    /// Explícitas para que agregar una propiedad no cambie el formato sin querer.
    private enum CodingKeys: String, CodingKey { case version, name, projects, connections, scripts, iconStyle }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        name = try values.decode(String.self, forKey: .name)
        projects = try values.decodeIfPresent([CodeProject].self, forKey: .projects) ?? []
        connections = try values.decodeIfPresent([DatabaseConnection].self, forKey: .connections) ?? []
        iconStyle = try values.decodeIfPresent(ProjectIconStyle.self, forKey: .iconStyle) ?? ProjectIconStyle()
        scripts = try values.decodeIfPresent([String].self, forKey: .scripts) ?? []
        scripts = Array(NSOrderedSet(array: scripts)) as? [String] ?? []
    }

    /// Orden de comprobaciones: versión, cantidades, longitudes, texto, rutas, IDs
    /// duplicados y conexiones. Las cantidades van primero para no recorrer un arreglo
    /// de cien mil elementos validando texto.
    static func read(from url: URL) throws -> Workspace {
        var value = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw WorkspaceError.unsupportedVersion }
        try value.checkFormat()
        value.scripts = Self.deduplicated(value.scripts)
        guard Set(value.projects.map(\.id)).count == value.projects.count else {
            throw WorkspaceError.duplicateProject
        }
        guard Set(value.connections.map(\.id)).count == value.connections.count else { throw WorkspaceError.duplicateProject }
        // Nivel lenient: un proyecto existente con una conexión remota sin TLS se
        // abre; el rechazo llega al intentar conectar, con un mensaje accionable.
        for connection in value.connections { _ = try connection.validated(.lenient) }
        return value
    }

    func checkFormat() throws {
        guard iconStyle.isValid else { throw WorkspaceError.invalidText("el color del icono") }
        try checkCounts()
        try checkLengths()
        try checkText()
        try checkPaths()
    }

    private func checkCounts() throws {
        try Self.checkCount(projects.count, WorkspaceLimits.projects, "subproyectos")
        try Self.checkCount(connections.count, WorkspaceLimits.connections, "conexiones")
        try Self.checkCount(scripts.count, WorkspaceLimits.scripts, "scripts SQL")
    }

    private static func checkCount(_ count: Int, _ limit: Int, _ what: String) throws {
        guard count > limit else { return }
        throw WorkspaceError.tooManyEntries("\(what) (\(limit) como máximo, el archivo trae \(count))")
    }

    private func checkLengths() throws {
        try Self.checkLength(name, WorkspaceLimits.nameLength, "el nombre del proyecto")
        for project in projects {
            try Self.checkLength(project.name, WorkspaceLimits.nameLength, "el nombre de «\(project.shortName)»")
            try Self.checkLength(project.path, WorkspaceLimits.pathLength, "la ruta de «\(project.shortName)»")
            try Self.checkLength(project.command, WorkspaceLimits.commandLength, "el comando de «\(project.shortName)»")
        }
        for script in scripts {
            try Self.checkLength(script, WorkspaceLimits.pathLength, "la ruta de un script SQL")
        }
    }

    private static func checkLength(_ value: String, _ limit: Int, _ what: String) throws {
        guard value.count > limit else { return }
        throw WorkspaceError.textTooLong("\(what) (\(limit) caracteres como máximo, el archivo trae \(value.count))")
    }

    private func checkText() throws {
        guard name.isValidProjectText() else { throw WorkspaceError.invalidText("el nombre del proyecto") }
        for project in projects {
            guard project.name.isValidProjectText() else {
                throw WorkspaceError.invalidText("el nombre de «\(project.shortName)»")
            }
            guard project.path.isValidProjectText() else {
                throw WorkspaceError.invalidText("la ruta de «\(project.shortName)»")
            }
            // Un comando multilínea es legítimo; el resto de los controles, no.
            guard project.command.isValidProjectText(newlines: true) else {
                throw WorkspaceError.invalidText("el comando de «\(project.shortName)»")
            }
        }
        for script in scripts where !script.isValidProjectText() {
            throw WorkspaceError.invalidText("la ruta de un script SQL")
        }
    }

    /// Una ruta relativa que sale del directorio del proyecto no se normaliza: si quiere
    /// salir, el archivo está mal formado o es hostil. Las absolutas sí se admiten —un
    /// proyecto legítimo puede tener carpetas afuera— y S1 las clasifica como externas.
    private func checkPaths() throws {
        for project in projects where Self.escapes(project.path) {
            throw WorkspaceError.escapingPath("«\(project.path)», de «\(project.shortName)»")
        }
        for script in scripts where Self.escapes(script) {
            throw WorkspaceError.escapingPath("«\(script)»")
        }
    }

    private static func escapes(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        return normalized(path).hasPrefix("..")
    }

    /// Normaliza sin tocar el disco: quita los componentes `.` y colapsa los `..` que
    /// puede. Así `"sql/a.sql"` y `"./sql/a.sql"` son la misma entrada.
    static func normalized(_ path: String) -> String {
        guard !path.hasPrefix("/") else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else {
                    components.append("..")
                }
            default:
                components.append(String(part))
            }
        }
        return components.joined(separator: "/")
    }

    private static func deduplicated(_ scripts: [String]) -> [String] {
        var seen: Set<String> = []
        return scripts.map(normalized).filter { seen.insert($0).inserted }
    }

    func write(to url: URL) throws {
        // Lo que la app genera cumple el formato por construcción. Esto está para que un
        // camino nuevo que lo rompa se note acá, y no al reabrir el proyecto.
        #if DEBUG
        do {
            try checkFormat()
        } catch {
            assertionFailure("se está escribiendo un .krabzik que la propia lectura rechazaría: "
                + (error.localizedDescription))
        }
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Todo lo que puede salir mal abriendo un proyecto o un archivo, con el mensaje que
/// ve el usuario. Los cuatro casos de C7 llevan el campo en el mensaje porque el
/// `.krabzik` es JSON legible y se puede corregir a mano.
enum WorkspaceError: LocalizedError, Equatable {
    case unsupportedVersion, duplicateProject, binaryFile, largeFile, externalChange, missingFolder
    /// Los tres de C7 llevan el campo y el subproyecto en el mensaje: el `.krabzik` es
    /// JSON legible y se puede corregir a mano si se sabe dónde mirar.
    case tooManyEntries(String)
    case textTooLong(String)
    case invalidText(String)
    case escapingPath(String)

    var errorDescription: String? {
        switch self {
        case .tooManyEntries(let detail): return "El proyecto declara demasiados \(detail)."
        case .textTooLong(let detail): return "Es demasiado largo \(detail)."
        case .invalidText(let detail): return "El proyecto contiene texto no válido en \(detail)."
        case .escapingPath(let detail): return "La ruta \(detail) sale del directorio del proyecto."
        case .unsupportedVersion: return "La versión de este proyecto no es compatible."
        case .duplicateProject: return "El proyecto contiene identificadores duplicados."
        case .binaryFile: return "Este archivo no es texto UTF-8."
        case .largeFile: return "El editor admite archivos de hasta 5 MB en esta versión."
        case .externalChange: return "El archivo cambió en el disco. Guardá una copia para conservar tus cambios."
        case .missingFolder: return "No se encuentra la carpeta del subproyecto."
        }
    }
}

/// Comillas para pasar una ruta a zsh sin que el shell la interprete.
enum Shell {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
