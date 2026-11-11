import Foundation

/// Datos del asistente; no se escribe nada hasta confirmar la creación.
struct ProjectDraft {
    var name = ""
    var libraryRoot = ProjectStorage.root
    var year = Calendar.current.component(.year, from: Date())
    private var customLocation: URL?
    private var customFolderName: String?
    var usesDefaultLocation: Bool { customLocation == nil }
    var location: URL {
        get { customLocation ?? libraryRoot.appendingPathComponent(String(year), isDirectory: true) }
        set { customLocation = newValue }
    }
    var folderName: String {
        get { customFolderName ?? ProjectStorage.folder(name: name, year: year, root: libraryRoot).lastPathComponent }
        set { customFolderName = newValue }
    }
    var folder: URL {
        get { location.appendingPathComponent(folderName, isDirectory: true) }
        set {
            customLocation = newValue.deletingLastPathComponent()
            customFolderName = newValue.lastPathComponent
        }
    }
    mutating func useDefaultLocation() { customLocation = nil
    customFolderName = nil }
    var icon = ProjectIconStyle()
    var projects: [CodeProject] = []
    var openWhenCreated = true

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var url: URL { folder.appendingPathComponent(trimmedName).appendingPathExtension(Workspace.fileExtension).standardizedFileURL }

    var validationMessage: String? {
        let name = trimmedName
        if name.isEmpty { return "Ingresá un nombre para el proyecto." }
        if name == "." || name == ".." || name.contains("/") || name.contains(":") || !name.isValidProjectText() {
            return "El nombre no puede contener /, : ni caracteres de control."
        }
        if name.count > WorkspaceLimits.nameLength || (name + "." + Workspace.fileExtension).utf8.count > 255 {
            return "Elegí un nombre más corto."
        }
        let component = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if component.isEmpty || component == "." || component == ".." || component.contains("/")
            || component.contains(":") || !component.isValidProjectText() {
            return "Ingresá un nombre de carpeta válido, sin /, : ni caracteres de control."
        }
        var directory: ObjCBool = false
        if !usesDefaultLocation {
            guard FileManager.default.fileExists(atPath: location.path, isDirectory: &directory), directory.boolValue else {
                return "Elegí una ubicación existente para crear la carpeta."
            }
        }
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory)
        if exists && !directory.boolValue {
            return "Elegí una carpeta existente para guardar el proyecto."
        }
        if folder.lastPathComponent.utf8.count > 255 { return "Elegí un nombre de carpeta más corto." }
        if FileManager.default.fileExists(atPath: url.path) { return "Ya existe un proyecto con ese nombre en esta ubicación." }
        return nil
    }

    func workspace() throws -> Workspace {
        if let validationMessage { throw ProjectDraftError.invalid(validationMessage) }
        var workspace = Workspace(name: trimmedName, projects: projects)
        workspace.iconStyle = icon
        for project in projects {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: project.path, isDirectory: &directory), directory.boolValue else {
                throw WorkspaceError.missingFolder
            }
        }
        try workspace.checkFormat()
        return workspace
    }

    /// La selección se normaliza para no agregar dos veces una carpeta o un symlink a ella.
    static func detect(_ urls: [URL]) throws -> [CodeProject] {
        var seen: Set<URL> = []
        return try urls.compactMap { url in
            let normalized = url.resolvingSymlinksInPath().standardizedFileURL
            var directory: ObjCBool = false
            guard url.isFileURL, FileManager.default.fileExists(atPath: normalized.path, isDirectory: &directory),
                  directory.boolValue else { throw WorkspaceError.missingFolder }
            guard seen.insert(normalized).inserted else { return nil }
            let (kind, command) = ProjectKind.detect(at: normalized)
            return CodeProject(name: normalized.lastPathComponent, path: normalized.path, kind: kind, command: command)
        }
    }
}

enum ProjectDraftError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Ubicación administrada; el nombre visible y el archivo conservan su escritura original.
enum ProjectStorage {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BraketProjects", isDirectory: true)
    }

    static func folder(name: String, year: Int, root: URL = root) -> URL {
        let words = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let component = words.map { word in
            let normalized = word == word.uppercased() ? word.lowercased() : word
            return normalized.prefix(1).uppercased() + normalized.dropFirst()
        }.joined()
        return root.appendingPathComponent(String(year), isDirectory: true)
            .appendingPathComponent(component.isEmpty ? "Proyecto" : component, isDirectory: true)
    }

    static func contains(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    }
}
