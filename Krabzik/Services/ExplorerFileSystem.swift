import Foundation

enum ExplorerFileError: LocalizedError, Equatable {
    case outsideProject, projectRoot, invalidName, alreadyExists, missingSource, invalidDestination, recursiveMove,
         processStillRunning, unsavedChanges, managedMetadata

    var errorDescription: String? {
        switch self {
        case .outsideProject: "La operación debe quedar dentro de una carpeta agregada al proyecto."
        case .projectRoot: "La carpeta raíz se administra desde Proyecto; sus archivos no se modificaron."
        case .invalidName: "Elegí un nombre de archivo válido, sin barras ni saltos de línea."
        case .alreadyExists: "Ya existe un elemento con ese nombre en la carpeta de destino."
        case .missingSource: "El archivo o la carpeta ya no existe. Actualizá el explorador."
        case .invalidDestination: "Elegí una carpeta de destino válida."
        case .recursiveMove: "No se puede poner una carpeta dentro de sí misma."
        case .processStillRunning: "Un proceso sigue en ejecución. Detenelo antes de mover o eliminar estos archivos."
        case .unsavedChanges: "Hay cambios sin guardar en una pestaña de este archivo. Guardalos antes de deshacer."
        case .managedMetadata: "Esta carpeta contiene datos internos de Braket. Gestioná las automatizaciones desde su editor."
        }
    }
}

/// Operaciones sobre archivos de un subproyecto montado. Nunca toca la carpeta raíz
/// ni resuelve un enlace simbólico para mover datos fuera del proyecto.
struct ExplorerFileSystem {
    let roots: [URL]
    private let files = FileManager.default

    init(roots: [URL]) {
        self.roots = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    static func contains(_ child: URL, in parent: URL) -> Bool {
        let child = child.standardizedFileURL.path, parent = parent.standardizedFileURL.path
        return child == parent || child.hasPrefix(parent + "/")
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains(":")
            && name.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }

    private func inRoot(_ url: URL, allowRoot: Bool) -> Bool {
        let path = url.standardizedFileURL
        // Resolver el padre, no el propio elemento: eliminar un symlink elimina el
        // enlace, pero un padre enlazado fuera del proyecto nunca da acceso de escritura.
        let parent = path.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return roots.contains { root in
            let isRoot = path.path == root.path
            return (allowRoot || !isRoot) && (isRoot || Self.contains(parent, in: root))
        }
    }

    private func isManagedMetadata(_ url: URL) -> Bool {
        roots.contains { root in
            guard Self.contains(url, in: root), url.path != root.path else { return false }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            return relative == ".braket" || relative.hasPrefix(".braket/")
        }
    }

    func checkedSource(_ url: URL) throws -> URL {
        let url = url.standardizedFileURL
        guard inRoot(url, allowRoot: false) else {
            throw roots.contains(where: { $0.path == url.path }) ? ExplorerFileError.projectRoot : .outsideProject
        }
        guard files.fileExists(atPath: url.path) else { throw ExplorerFileError.missingSource }
        guard !isManagedMetadata(url) else { throw ExplorerFileError.managedMetadata }
        // Una carpeta que contiene la raíz de otro subproyecto tampoco se mueve ni elimina.
        guard !roots.contains(where: { $0.path != url.path && Self.contains($0, in: url) }) else {
            throw ExplorerFileError.projectRoot
        }
        return url
    }

    func checkedFolder(_ url: URL) throws -> URL {
        let folder = url.resolvingSymlinksInPath().standardizedFileURL
        guard roots.contains(where: { Self.contains(folder, in: $0) }) else { throw ExplorerFileError.outsideProject }
        guard !isManagedMetadata(folder) else { throw ExplorerFileError.managedMetadata }
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExplorerFileError.invalidDestination
        }
        return folder
    }

    func destination(name: String, in folder: URL) throws -> URL {
        guard Self.validName(name) else { throw ExplorerFileError.invalidName }
        return try checkedFolder(folder).appendingPathComponent(name).standardizedFileURL
    }

    func create(name: String, in folder: URL, directory: Bool) throws -> URL {
        let target = try destination(name: name, in: folder)
        guard !files.fileExists(atPath: target.path) else { throw ExplorerFileError.alreadyExists }
        if directory { try files.createDirectory(at: target, withIntermediateDirectories: false) }
        else { try Data().write(to: target, options: .withoutOverwriting) }
        return target
    }

    func copy(_ source: URL, to folder: URL, name: String? = nil, external: Bool = false) throws -> URL {
        let source = external ? source.standardizedFileURL : try checkedSource(source)
        guard files.fileExists(atPath: source.path) else { throw ExplorerFileError.missingSource }
        let target = try destination(name: name ?? source.lastPathComponent, in: folder)
        guard !files.fileExists(atPath: target.path) else { throw ExplorerFileError.alreadyExists }
        guard !Self.contains(target, in: source) else { throw ExplorerFileError.recursiveMove }
        try files.copyItem(at: source, to: target)
        return target
    }

    func move(_ source: URL, to folder: URL, name: String? = nil) throws -> URL {
        let source = try checkedSource(source)
        let target = try destination(name: name ?? source.lastPathComponent, in: folder)
        guard source != target else { return source }
        guard !files.fileExists(atPath: target.path) else { throw ExplorerFileError.alreadyExists }
        guard !Self.contains(target, in: source) else { throw ExplorerFileError.recursiveMove }
        try files.moveItem(at: source, to: target)
        return target
    }

    func trash(_ source: URL) throws -> URL {
        let source = try checkedSource(source)
        var result: NSURL?
        try files.trashItem(at: source, resultingItemURL: &result)
        guard let result else { throw ExplorerFileError.missingSource }
        return result as URL
    }

    func availableName(for name: String, in folder: URL) throws -> String {
        guard Self.validName(name) else { throw ExplorerFileError.invalidName }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        for number in 2...999 {
            let candidate = "\(stem) \(number)" + (ext.isEmpty ? "" : ".\(ext)")
            if !files.fileExists(atPath: try destination(name: candidate, in: folder).path) { return candidate }
        }
        throw ExplorerFileError.alreadyExists
    }
}
