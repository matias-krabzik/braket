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

    /// Guarda el documento. Lanza si el archivo cambió en disco desde que se leyó.
    @discardableResult
    func save(_ document: EditorDocument) async throws -> Bool {
        guard document.previewImage == nil else { return false }
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
        for document in documents where predicate(document.url) {
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
