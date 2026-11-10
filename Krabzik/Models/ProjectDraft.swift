import Foundation

/// Datos del asistente; no se escribe nada hasta confirmar la creación.
struct ProjectDraft {
    var name = ""
    var folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    var icon = ProjectIconStyle()
    var projects: [CodeProject] = []
    var openWhenCreated = true

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var url: URL { folder.appendingPathComponent(trimmedName + ".krabzik").standardizedFileURL }

    var validationMessage: String? {
        let name = trimmedName
        if name.isEmpty { return "Ingresá un nombre para el proyecto." }
        if name == "." || name == ".." || name.contains("/") || name.contains(":") || !name.isValidProjectText() {
            return "El nombre no puede contener /, : ni caracteres de control."
        }
        if name.count > WorkspaceLimits.nameLength || (name + ".krabzik").utf8.count > 255 {
            return "Elegí un nombre más corto."
        }
        var directory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) || !directory.boolValue {
            return "Elegí una carpeta existente para guardar el proyecto."
        }
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
