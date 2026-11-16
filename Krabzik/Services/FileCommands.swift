import AppKit
import Foundation
import UniformTypeIdentifiers

struct FileOperationStatus {
    var action: String
    var filename = ""
    var completed = 0
    var total: Int
}

/// Lo que el usuario le pide al editor sobre un archivo: abrirlo, crearlo, guardarlo,
/// cerrarlo, recargarlo, y la lista de scripts del proyecto.
///
/// Es la mitad que pregunta y reporta. `DocumentStore` hace el trabajo de disco y no
/// tiene diálogos; acá están las decisiones que necesitan al usuario —si guardar antes de
/// cerrar, si descartar lo escrito al recargar— y un único sitio donde los errores de
/// archivo llegan al `ErrorCenter`. Por eso guardar desde ⌘S, desde el cierre de una
/// pestaña y desde el envío a Codex pasan todos por `save(_:)` y dicen lo mismo.
///
/// Confinado al main actor. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor
final class FileCommands {
    private let session: WorkspaceSession
    private let docs: DocumentStore
    private let defaults: UserDefaults
    private static let scriptsDirectoriesKey = "sql.projectScriptsDirectories.v1"
    var requestNewFile: ((URL?) -> Void)?
    var requestNewPixelArt: ((URL?) -> Void)?
    var didSaveDraft: ((EditorDocument) -> Void)?
    var onOpen: (() -> Void)?

    init(session: WorkspaceSession, docs: DocumentStore, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.session = session
        self.docs = docs
    }

    /// `nil` cuando la ruta no se puede ofrecer: en solo lectura no se resuelven rutas
    /// externas, que es por donde un `.kzk` ajeno abriría archivos de cualquier parte.
    func scriptURL(_ path: String) -> URL? {
        guard let workspaceURL = session.url else { return nil }
        return ScriptLibrary.url(for: path, workspaceURL: workspaceURL, trust: session.trust)
    }

    var standaloneScripts: [URL] {
        guard let workspace = session.workspace, let url = session.url else { return [] }
        return ScriptLibrary.standaloneURLs(in: workspace, at: url, trust: session.trust)
    }

    func removeScript(_ url: URL) {
        guard !session.isReadOnly, var workspace = session.workspace else { return }
        workspace.scripts.removeAll { scriptURL($0)?.standardizedFileURL == url.standardizedFileURL }
        session.write(workspace)
    }

    func importScripts() {
        guard session.workspace != nil else { return }
        for url in session.dialogs.chooseScripts() {
            remember(url)
            open(url)
        }
    }

    /// Agrega el script a la lista del proyecto, si `ScriptLibrary` dice que corresponde.
    func remember(_ url: URL) {
        guard let workspace = session.workspace, let workspaceURL = session.url,
              let updated = ScriptLibrary.remembering(url, in: workspace, at: workspaceURL) else { return }
        session.write(updated)
    }

    /// Abre el archivo en una pestaña. Un archivo cuyo proyecto se cerró mientras se leía
    /// se descarta: el `stillValid` lo comprueba después de la lectura.
    func open(_ url: URL) {
        let currentWorkspace = session.url
        Task {
            do {
                try await docs.open(url) { self.session.url == currentWorkspace }
                if session.url == currentWorkspace, docs.selectedID == url.standardizedFileURL { onOpen?() }
            } catch {
                session.errors.report(error)
            }
        }
    }

    func create(in directory: URL? = nil) {
        guard !session.isReadOnly, session.url != nil else { return }
        requestNewFile?(directory)
    }

    func createPixelArt(in directory: URL? = nil) {
        guard !session.isReadOnly else { return }
        if session.url != nil {
            requestNewPixelArt?(directory)
            return
        }
        guard let options = WorkspacePrompts.pixelArtCanvas(name: nil, width: 64, height: 64) else { return }
        do {
            _ = try docs.createPixelDraft(width: options.width, height: options.height)
            onOpen?()
        } catch { session.errors.report(error) }
    }

    func createPixelArtFile(named name: String, in folder: URL,
                            width: Int = 64, height: Int = 64) async throws -> EditorDocument {
        guard !session.isReadOnly, let workspaceURL = session.url else {
            throw ExplorerFileError.outsideProject
        }
        let filename = URL(fileURLWithPath: name).pathExtension.isEmpty ? name + ".pxa" : name
        guard filename.lowercased().hasSuffix(".pxa"), ExplorerFileSystem.validName(filename) else {
            throw PixelArtError.invalid("archivo", "elegí un nombre válido con extensión .pxa")
        }
        let roots = session.mountedProjects.map { $0.directory(relativeTo: workspaceURL) }
        let destination = try ExplorerFileSystem(roots: roots).destination(name: filename, in: folder)
        let document = try await docs.createPixelArt(at: destination, width: width, height: height)
        session.touch()
        onOpen?()
        return document
    }

    func choosePixelArt() {
        let panel = NSOpenPanel()
        panel.title = "Abrir imagen pixel art"
        panel.allowedContentTypes = [UTType(filenameExtension: "pxa") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    func createTableQuery(_ table: SQLSchemaTable) async -> EditorDocument? {
        guard !session.isReadOnly, session.url != nil else { return nil }
        do {
            let suggested = table.name + ".sql"
            let name = ExplorerFileSystem.validName(suggested) ? suggested : "consulta.sql"
            return try docs.createDraft(name: name, text: "SELECT * FROM \(table.qualified);\n")
        } catch {
            session.errors.report(error)
            return nil
        }
    }

    func relocateScripts(from source: URL, to destination: URL) {
        guard var workspace = session.workspace, let workspaceURL = session.url else { return }
        let base = workspaceURL.deletingLastPathComponent().path + "/"
        var changed = false
        workspace.scripts = workspace.scripts.map { path in
            guard let url = scriptURL(path), ExplorerFileSystem.contains(url, in: source) else { return path }
            let suffix = String(url.path.dropFirst(source.standardizedFileURL.path.count))
            let target = destination.standardizedFileURL.path + suffix
            changed = true
            return target.hasPrefix(base) ? String(target.dropFirst(base.count)) : target
        }
        if changed { session.write(workspace) }
    }

    /// Renombra sin descartar el buffer de una pestaña ni sobrescribir otro archivo.
    func rename(_ url: URL) -> URL? {
        guard !session.isReadOnly, let workspaceURL = session.url,
              var workspace = session.workspace else { return nil }
        let url = url.standardizedFileURL
        guard let name = WorkspacePrompts.nameForNewItem("Renombrar archivo", suggested: url.lastPathComponent, action: "Renombrar"),
              name != url.lastPathComponent else { return nil }
        var roots = session.mountedProjects.map { $0.directory(relativeTo: workspaceURL) }
        if !roots.contains(where: { ExplorerFileSystem.contains(url, in: $0) }),
           standaloneScripts.contains(url) || docs.documents.contains(where: { $0.url.standardizedFileURL == url }) {
            roots.append(url.deletingLastPathComponent())
        }
        do {
            let result = try ExplorerFileSystem(roots: roots).move(url, to: url.deletingLastPathComponent(), name: name)
            docs.relocate(from: url, to: result)
            let base = workspaceURL.deletingLastPathComponent().path + "/"
            workspace.scripts = workspace.scripts.map { path in
                guard scriptURL(path)?.standardizedFileURL == url else { return path }
                return result.path.hasPrefix(base) ? String(result.path.dropFirst(base.count)) : result.path
            }
            session.write(workspace)
            session.touch()
            return result
        } catch {
            session.errors.report(error)
            return nil
        }
    }

    private func scriptsDirectory() -> URL? {
        guard !session.isReadOnly, let workspaceURL = session.url else { return nil }
        let key = workspaceURL.standardizedFileURL.path
        var directories = defaults.dictionary(forKey: Self.scriptsDirectoriesKey) as? [String: String] ?? [:]
        if let path = directories[key] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        guard let directory = session.dialogs.chooseScriptsDirectory(workspaceURL.deletingLastPathComponent()) else { return nil }
        directories[key] = directory.standardizedFileURL.path
        defaults.set(directories, forKey: Self.scriptsDirectoriesKey)
        return directory
    }

    @discardableResult
    func save(_ document: EditorDocument) async -> Bool {
        do {
            if document.isDraft {
                if document.pixelArt != nil {
                    let directory = session.url?.deletingLastPathComponent()
                        ?? FileManager.default.homeDirectoryForCurrentUser
                    guard let url = session.dialogs.saveCopy("Sin título.pxa", directory),
                          url.pathExtension.lowercased() == "pxa" else { return false }
                    _ = try await docs.savePixelDraft(document, to: url)
                    session.touch()
                    return true
                }
                guard let directory = scriptsDirectory(),
                      let url = session.dialogs.saveCopy(document.url.lastPathComponent, directory) else { return false }
                let saved = try docs.saveDraft(document, to: url)
                didSaveDraft?(saved)
                remember(url)
                session.touch()
                return true
            }
            return try await docs.save(document)
        } catch {
            session.errors.report(error)
            return false
        }
    }

    func saveCopy() {
        guard let document = docs.selected else { return }
        let suggested = document.url.deletingPathExtension().lastPathComponent
            + "-copia." + document.url.pathExtension
        guard let url = session.dialogs.saveCopy(suggested, document.isDraft ?
            (session.url?.deletingLastPathComponent() ?? document.url.deletingLastPathComponent()) :
            document.url.deletingLastPathComponent()) else { return }
        do {
            try docs.saveCopy(of: document, to: url)
            session.touch()
        } catch {
            session.errors.report(error)
        }
    }

    func exportPixelPNG() {
        guard let document = docs.selected, let art = document.pixelArt,
              let frame = art.editor.activeFrameID else { return }
        let panel = NSSavePanel()
        panel.title = "Exportar PNG"
        panel.nameFieldStringValue = document.isDraft ? "pixel-art.png" :
            document.url.deletingPathExtension().lastPathComponent + ".png"
        panel.allowedContentTypes = [.png]
        panel.directoryURL = document.isDraft ? session.url?.deletingLastPathComponent() :
            document.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let state = art.state
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    guard let png = PixelArtPreview.fullSizePNG(of: state, frame: frame) else {
                        throw WorkspaceError.invalidImage
                    }
                    try png.write(to: destination, options: .atomic)
                }.value
            } catch { session.errors.report(error) }
        }
    }

    /// Cierra la pestaña, preguntando lo que haga falta: primero por la consulta que
    /// todavía está corriendo, después por los cambios sin guardar. `false` si el usuario
    /// canceló en cualquiera de las dos.
    ///
    /// Quién cancela la consulta llega como parámetro: así acá no hay nada de MySQL y se
    /// puede cerrar una pestaña en una prueba sin levantar la base.
    @discardableResult
    func close(_ document: EditorDocument,
               cancelQuery: @MainActor (SQLExecution) -> Void = { _ in }) async -> Bool {
        if document.sqlExecution.isRunning {
            guard session.dialogs.confirmCancelQuery() else { return false }
            cancelQuery(document.sqlExecution)
        }
        guard document.sqlExecution.drafts.values.allSatisfy({ !$0.sending && $0.confirmDiscard() }) else { return false }
        guard await confirmSave(document) else { return false }
        docs.close(docs.documents.first { $0.sqlExecution === document.sqlExecution } ?? document)
        return true
    }

    func reload(_ document: EditorDocument) {
        guard !document.isDraft else { return }
        if document.isDirty, !session.dialogs.confirmDiscardChanges(document.url.lastPathComponent) {
            return
        }
        do {
            try docs.reload(document)
        } catch {
            session.errors.report(error)
        }
    }

    /// `true` si se puede seguir: se guardó, o el usuario decidió descartar.
    func confirmSave(_ document: EditorDocument) async -> Bool {
        guard document.isDirty else { return true }
        switch session.dialogs.confirmSave(document.url.lastPathComponent) {
        case .save: return await save(document)
        case .discard: return true
        case .cancel: return false
        }
    }

    /// Resuelve todos los documentos con cambios sin guardar, de a uno. `false` en cuanto
    /// el usuario cancele: dejar un proyecto no puede perder lo que escribió.
    func resolveDirty() async -> Bool {
        for document in docs.documents {
            guard document.sqlExecution.drafts.values.allSatisfy({ !$0.sending && $0.confirmDiscard() }) else { return false }
        }
        for document in docs.dirty {
            if !(await confirmSave(document)) { return false }
        }
        return true
    }
}
