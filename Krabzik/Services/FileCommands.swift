import Foundation

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

    init(session: WorkspaceSession, docs: DocumentStore) {
        self.session = session
        self.docs = docs
    }

    /// `nil` cuando la ruta no se puede ofrecer: en solo lectura no se resuelven rutas
    /// externas, que es por donde un `.kzk` ajeno abriría archivos de cualquier parte.
    func scriptURL(_ path: String) -> URL? {
        guard let workspaceURL = session.url else { return nil }
        return ScriptLibrary.url(for: path, workspaceURL: workspaceURL, trust: session.trust)
    }

    func importScripts() {
        guard session.workspace != nil else { return }
        for url in session.dialogs.chooseScripts() {
            remember(url)
            open(url)
        }
    }

    /// Agrega el script a la lista del proyecto, si `ScriptLibrary` dice que corresponde.
    private func remember(_ url: URL) {
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
            } catch {
                session.errors.report(error)
            }
        }
    }

    func create(in directory: URL? = nil) {
        guard session.workspace != nil else { return }
        let suggested = directory
            ?? docs.selected?.url.deletingLastPathComponent()
            ?? session.url?.deletingLastPathComponent()
        guard let url = session.dialogs.createFile("nuevo.sql", suggested) else { return }
        do {
            // El panel de guardar ya resolvió la confirmación de sobrescribir.
            try Data().write(to: url, options: .atomic)
            remember(url)
            session.touch()
            open(url)
        } catch { session.errors.report(error) }
    }

    @discardableResult
    func save(_ document: EditorDocument) async -> Bool {
        do {
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
        guard let url = session.dialogs.saveCopy(suggested, document.url.deletingLastPathComponent()) else { return }
        do {
            try docs.saveCopy(of: document, to: url)
            session.touch()
        } catch {
            session.errors.report(error)
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
        guard await confirmSave(document) else { return false }
        docs.close(document)
        return true
    }

    func reload(_ document: EditorDocument) {
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
        for document in docs.dirty {
            if !(await confirmSave(document)) { return false }
        }
        return true
    }
}
