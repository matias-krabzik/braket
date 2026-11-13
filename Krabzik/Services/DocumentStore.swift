import Foundation
import Observation

/// Los archivos abiertos en el editor: cuáles hay, cuál está seleccionado, y las
/// operaciones de disco.
///
/// **Acá no hay diálogos.** Las operaciones lanzan o devuelven qué pasó, y quien decide
/// con el usuario —si guardar antes de cerrar, si descartar cambios al recargar— es el
/// coordinador. Por eso se puede ejercitar en pruebas sin que aparezca ningún `NSAlert`,
/// que es el criterio 5 de C5.
///
/// Guardar no pisa un cambio externo: `DocumentIO.save` compara el disco con lo que se
/// leyó y lanza `WorkspaceError.externalChange` si no coincide.
///
/// Confinado al main actor. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor @Observable
final class DocumentStore {
    private(set) var documents: [EditorDocument] = []
    var selectedID: URL?
    /// Archivos que se están leyendo. La interfaz los muestra como en curso, y sirve para
    /// no lanzar dos lecturas del mismo archivo.
    private(set) var openingFiles: Set<URL> = []

    var selected: EditorDocument? { documents.first { $0.id == selectedID } }

    func contains(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        return documents.contains { $0.id == url }
    }

    func affected(by url: URL) -> [EditorDocument] {
        documents.filter { ExplorerFileSystem.contains($0.url, in: url) }
    }

    /// Al mover una carpeta, las pestañas siguen al archivo y conservan el texto sin
    /// guardar. El editor nativo se recrea con la nueva URL en la siguiente renderización.
    func relocate(from source: URL, to destination: URL) {
        // The source no longer exists after a move. Resolve the surviving ancestor,
        // then append its missing components so symlinked project roots still match.
        func canonical(_ url: URL) -> URL {
            var ancestor = url.standardizedFileURL
            var missing: [String] = []
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                missing.insert(ancestor.lastPathComponent, at: 0)
                ancestor.deleteLastPathComponent()
            }
            return missing.reduce(ancestor.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.standardizedFileURL
        }
        let source = canonical(source), destination = destination.standardizedFileURL
        documents = documents.map { document in
            let current = canonical(document.url)
            guard ExplorerFileSystem.contains(current, in: source) else { return document }
            document.releaseEditor()
            let suffix = String(current.path.dropFirst(source.path.count))
            let newURL = URL(fileURLWithPath: destination.path + suffix).standardizedFileURL
            return EditorDocument(relocating: document, to: newURL)
        }
        if let selectedID, ExplorerFileSystem.contains(canonical(selectedID), in: source) {
            let suffix = String(canonical(selectedID).path.dropFirst(source.path.count))
            self.selectedID = URL(fileURLWithPath: destination.path + suffix).standardizedFileURL
        }
    }

    /// Abre el archivo y lo selecciona. Si ya estaba abierto solo lo selecciona, y si ya
    /// se está leyendo no hace nada.
    ///
    /// `stillValid` se evalúa **después** de leer el disco: el coordinador usa eso para
    /// descartar un archivo cuyo proyecto se cerró mientras se leía.
    func open(_ url: URL, stillValid: @MainActor @escaping () -> Bool = { true }) async throws {
        let url = url.standardizedFileURL
        if contains(url) {
            selectedID = url
            return
        }
        guard !openingFiles.contains(url) else { return }
        openingFiles.insert(url)
        defer { openingFiles.remove(url) }
        let document: EditorDocument
        if DocumentIO.isPreviewableImage(url) {
            let preview = try await Task.detached(priority: .userInitiated) { try DocumentIO.preview(url) }.value
            guard stillValid() else { return }
            document = try EditorDocument(url: url, previewData: preview)
        } else {
            let data = try await Task.detached(priority: .userInitiated) { try DocumentIO.read(url) }.value
            guard stillValid() else { return }
            document = try EditorDocument(url: url, data: data)
        }
        documents.append(document)
        selectedID = document.id
    }

    func createDraft(name: String, text: String) throws -> EditorDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Braket-Drafts")
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
        let document = try EditorDocument(url: url, data: Data(text.utf8))
        document.isDraft = true
        document.isDirty = true
        documents.append(document)
        selectedID = document.id
        return document
    }

    func saveDraft(_ document: EditorDocument, to url: URL) throws -> EditorDocument {
        guard document.isDraft, !contains(url) else { throw DatabaseFailure("El archivo ya está abierto en otra pestaña.") }
        let data = Data(document.text.utf8)
        try data.write(to: url, options: .atomic)
        let saved = EditorDocument(relocating: document, to: url)
        saved.isDraft = false
        saved.isDirty = false
        saved.originalData = data
        document.releaseEditor()
        documents = documents.map { $0 === document ? saved : $0 }
        if selectedID == document.id { selectedID = saved.id }
        return saved
    }

    /// Guarda el documento. Lanza si el archivo cambió en disco desde que se leyó.
    @discardableResult
    func save(_ document: EditorDocument) async throws -> Bool {
        guard !document.isDraft, document.previewImage == nil else { return false }
        guard !document.isSaving else { return false }
        document.isSaving = true
        defer { document.isSaving = false }
        let data = Data(document.text.utf8), expected = document.originalData, url = document.url
        try await Task.detached(priority: .userInitiated) {
            try DocumentIO.save(data, to: url, expected: expected)
        }.value
        document.originalData = data
        // El usuario pudo seguir escribiendo mientras se guardaba.
        document.isDirty = Data(document.text.utf8) != data
        return true
    }

    /// Escribe una copia en otra ruta. El documento abierto no cambia.
    func saveCopy(of document: EditorDocument, to url: URL) throws {
        if document.previewImage != nil {
            try Data(contentsOf: document.url, options: .mappedIfSafe).write(to: url, options: .atomic)
        } else {
            try Data(document.text.utf8).write(to: url, options: .atomic)
        }
    }

    /// Lo cierra y selecciona el vecino. No pregunta nada: quien decide si hay que
    /// guardar primero es el coordinador.
    func close(_ document: EditorDocument) {
        let index = documents.firstIndex { $0.id == document.id } ?? 0
        document.releaseEditor()
        documents.removeAll { $0.id == document.id }
        guard selectedID == document.id else { return }
        selectedID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
    }

    /// Relee el archivo descartando lo que el usuario escribió.
    func reload(_ document: EditorDocument) throws {
        if document.previewImage != nil {
            try document.acceptExternalPreviewData(DocumentIO.preview(document.url))
        } else {
            document.acceptExternalData(try DocumentIO.read(document.url), discardEdits: true)
        }
    }

    /// Relee del disco los documentos que cumplen el predicado, para cuando algo de
    /// afuera los cambió. No sabe quién los cambió: el agente, un `git checkout` o el
    /// usuario en otro editor.
    ///
    /// Un documento que ya no está en la lista, o cuyo contexto dejó de valer, se omite:
    /// la lectura es asíncrona y el proyecto puede cerrarse en el medio.
    func refresh(matching predicate: @escaping (URL) -> Bool,
                 stillValid: @MainActor @escaping () -> Bool = { true }) async {
        for document in documents where !document.isDraft && predicate(document.url) {
            let url = document.url
            let data = try? await Task.detached(priority: .utility) {
                try DocumentIO.isPreviewableImage(url) ? DocumentIO.preview(url) : DocumentIO.read(url)
            }.value
            guard stillValid(), documents.contains(where: { $0 === document }) else { continue }
            if let data, document.previewImage != nil {
                try? document.acceptExternalPreviewData(data)
            } else if let data { document.acceptExternalData(data) }
            else { document.hasExternalChange = true }
        }
    }

    /// Cierra todo y suelta las vistas nativas. Se llama al cambiar de proyecto.
    func closeAll() {
        for document in documents { document.releaseEditor() }
        documents.removeAll()
        selectedID = nil
    }

    /// Los que tienen cambios sin guardar.
    var dirty: [EditorDocument] { documents.filter(\.isDirty) }
}
