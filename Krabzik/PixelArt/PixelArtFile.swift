import Foundation

/// Lectura, validación y escritura de un `.pxa` completo (PXA-01 §1–§2 y §6).
/// El orden de validación es el del spec: envoltorio y presupuesto → manifiesto y versión → hashes y tipos →
/// entidades y límites → referencias → grafo histórico → concordancia del cursor → datos auxiliares.
/// Un error dice sección y causa; nunca se sustituye un bloque roto por vacío ni se repara una referencia.
enum PixelArtFile {
    /// Una generación del archivo lista para escribir, con la marca de lo que contiene.
    struct Snapshot: Sendable {
        var data: Data
        var manifest: PxaManifest
        var mark: PixelArtDocument.SavedMark
    }

    // MARK: Leer

    static func read(_ data: Data) throws -> PixelArtDocument {
        let entries = try PxaZip.read(data)
        guard let manifestEntry = entries.first(where: { $0.name == PxaZip.manifestName }) else {
            throw PixelArtError.invalid("manifiesto", "falta manifest.json")
        }
        let manifest = try PxaManifest.parse(manifestEntry.data)
        var warnings: [String] = []
        let store = try objectStore(from: entries, manifest: manifest, warnings: &warnings)

        let history = try PixelHistoryCodec.decode(manifest.history, from: store)
        guard history.currentState == manifest.currentState else {
            throw PixelArtError.invalid("concordancia", "el estado actual del manifiesto no es el de la revisión que señala el cursor")
        }
        let editor = try PixelEditorStateCodec.decode(manifest.editorState, from: store)
        let presets = try PixelExportPresetsCodec.decode(manifest.exportPresets, from: store)
        let assistant = try manifest.assistantState.map { try PixelAssistantCodec.decode($0, from: store) } ?? PixelAssistantState()

        let live = try store.reachable(from: manifest.roots)
        guard live == store.hashes else {
            throw PixelArtError.invalid("objetos", "el archivo contiene \(store.count - live.count) objetos que nada referencia")
        }
        let used = try validateHistory(history, assistant: assistant, store: store, nextPaletteEntryID: manifest.nextPaletteEntryID)
        let core = try PixelDocumentCore(documentID: manifest.documentID, store: store, history: history,
                                         nextPaletteEntryID: manifest.nextPaletteEntryID, everUsedEntryIDs: used)
        var normalized = editor
        if normalized
            .normalize(for: core.state) {
            warnings.append("El estado de edición del archivo apuntaba a elementos que ya no existen y se ajustó.") }
        try validateSelection(editor.selection, against: core.state, section: "estado de edición")
        var document = PixelArtDocument(core: core, editor: normalized, assistant: assistant, exportPresets: presets,
                                        createdAt: manifest.createdAt,
                                        copiedFrom: manifest.copiedFrom, partialHistory: manifest.partialHistory,
                                        extensions: manifest.extensions, isReadOnly: manifest.isReadOnly, warnings: warnings)
        document.assistant.revalidate(core: core)
        document.markSaved(PixelArtDocument.SavedMark(history: history, editor: editor, assistant: assistant.preparedForSave(),
                                                      exportPresets: presets,
                                                      saveID: manifest.saveID))
        return document
    }

    private static func validateSelection(_ selection: PixelSelection?, against state: PixelArtState, section: String) throws {
        try selection?.validateBounds(width: state.width, height: state.height, section: section)
    }

    /// Hashes de cada entrada contra su nombre, totales contra el manifiesto y miniatura aceptable o descartada.
    private static func objectStore(from entries: [PxaZip.Entry], manifest: PxaManifest,
                                    warnings: inout [String]) throws -> PxaObjectStore {
        var objects: [String: Data] = [:]
        for entry in entries {
            if entry.name == PxaZip.previewName {
                if PixelArtPreview
                    .isAcceptable(entry.data) == false { warnings.append("La miniatura del archivo no es válida y se regenerará.") }
                continue
            }
            guard entry.name.hasPrefix(PxaZip.objectPrefix) else { continue }
            let hash = String(entry.name.dropFirst(PxaZip.objectPrefix.count))
            guard PxaObjectStore.hash(of: entry.data) == hash else {
                throw PixelArtError.integrity("objeto \(hash.prefix(8))", "el contenido no coincide con su hash")
            }
            objects[hash] = entry.data
        }
        let store = PxaObjectStore(objects: objects)
        guard store.count == manifest.objectCount, store.totalBytes == manifest.uncompressedBytes else {
            throw PixelArtError.integrity("manifiesto", "los totales declarados no coinciden con los objetos del archivo")
        }
        return store
    }

    /// Resumen de un estado retenido, suficiente para comprobar `affected` y las selecciones sin conservar el estado.
    private struct StateSummary {
        var layers: Set<UUID>
        var frames: Set<UUID>
        var entries: Set<UInt32>
        var width: Int
        var height: Int
    }

    /// Todos los estados retenidos —incluso los de una rama inactiva y los de propuestas guardadas— deben cumplir los
    /// límites del modelo. Devuelve todos los IDs de paleta que alguna vez aparecieron, para el asignador.
    private static func validateHistory(_ history: PixelHistory, assistant: PixelAssistantState, store: PxaObjectStore,
                                        nextPaletteEntryID: UInt32) throws -> Set<UInt32> {
        var cache = PixelDecodeCache()
        var summaries: [String: StateSummary] = [:]
        var used = Set<UInt32>()
        func summary(_ ref: PxaObjectRef) throws -> StateSummary {
            if let known = summaries[ref.hash] { return known }
            let state = try PixelArtStateCodec.decode(ref, from: store, cache: &cache)
            let result = StateSummary(layers: Set(state.layers.map(\.id)), frames: Set(state.frames.map(\.id)), entries: state.palette.ids,
                                      width: state.width, height: state.height)
            used.formUnion(result.entries)
            summaries[ref.hash] = result
            return result
        }
        for revision in history.revisions.values {
            let after = try summary(revision.afterState)
            let before = try revision.beforeState.map(summary)
            try validateAffected(revision, before: before, after: after)
            try revision.focusAfter.selection?.validateBounds(width: after.width, height: after.height, section: "historial")
            let reference = before ?? after
            try revision.focusBefore.selection?.validateBounds(width: reference.width, height: reference.height, section: "historial")
            if let record = revision.assistantRecord { try PixelAssistantCodec.validateRecord(record, from: store) }
        }
        var reserved = Set<UInt32>()
        for proposal in assistant.proposals {
            if let ref = proposal.proposedState { used.formUnion(try summary(ref).entries) }
            reserved.formUnion(proposal.reservedEntryIDs)
            if proposal.status == .applied, let applied = proposal.appliedRevisionID, history.revision(applied) == nil {
                throw PixelArtError.invalid("asistente", "una propuesta aplicada apunta a una revisión que no existe")
            }
        }
        let highest = used.union(reserved).max() ?? 0
        guard nextPaletteEntryID > highest else {
            throw PixelArtError.invalid("manifiesto", "el contador de paleta (\(nextPaletteEntryID)) no supera el ID \(highest) ya usado")
        }
        return used
    }

    private static func validateAffected(_ revision: PixelRevision, before: StateSummary?, after: StateSummary) throws {
        let layers = after.layers.union(before?.layers ?? [])
        let frames = after.frames.union(before?.frames ?? [])
        let entries = after.entries.union(before?.entries ?? [])
        let width = max(after.width, before?.width ?? 0)
        let height = max(after.height, before?.height ?? 0)
        guard Set(revision.affected.layers).isSubset(of: layers), Set(revision.affected.frames).isSubset(of: frames),
              Set(revision.affected.paletteEntries).isSubset(of: entries) else {
            throw PixelArtError.invalid("historial", "«\(revision.label)» declara afectar elementos que no existen en sus estados")
        }
        for region in revision.affected.regions {
            guard layers.contains(region.layerID), frames.contains(region.frameID), region.x + region.width <= width,
                  region.y + region.height <= height else {
                throw PixelArtError.invalid("historial", "«\(revision.label)» declara una región fuera de sus estados")
            }
        }
    }

    // MARK: Recuperar

    /// Abre como copia recuperada cuando solo falla la historia pero el estado actual se puede verificar por completo.
    /// Es otro documento-ID, con ese estado como origen y sin presentar la copia como poseedora de la historia
    /// completa. Requiere una elección explícita del usuario y nunca sobrescribe el original.
    static func recoveredCopy(from data: Data) throws -> PixelArtDocument {
        let entries = try PxaZip.read(data)
        guard let manifestEntry = entries.first(where: { $0.name == PxaZip.manifestName }) else {
            throw PixelArtError.invalid("manifiesto", "falta manifest.json")
        }
        let manifest = try PxaManifest.parse(manifestEntry.data)
        var warnings: [String] = []
        var objects: [String: Data] = [:]
        for entry in entries where entry.name.hasPrefix(PxaZip.objectPrefix) {
            let hash = String(entry.name.dropFirst(PxaZip.objectPrefix.count))
            if PxaObjectStore.hash(of: entry.data) == hash { objects[hash] = entry.data }
        }
        let full = PxaObjectStore(objects: objects)
        let state = try PixelArtStateCodec.decode(manifest.currentState, from: full)
        try state.validate()
        var store = PxaObjectStore()
        let ref = PixelArtStateCodec.encode(state, into: &store)
        let history = PixelHistory(initialState: ref, label: "Copia recuperada", source: .system)
        let ids = state.palette.ids
        let core = try PixelDocumentCore(documentID: UUID(), store: store, history: history,
                                         nextPaletteEntryID: max(manifest.nextPaletteEntryID, (ids.max() ?? 0) + 1), everUsedEntryIDs: ids)
        warnings.append("Copia recuperada: conserva el estado actual del archivo, no su historial completo.")
        return PixelArtDocument(core: core, editor: PixelEditorState.initial(for: state), assistant: PixelAssistantState(),
                                exportPresets: [],
                                createdAt: manifest.createdAt, copiedFrom: manifest.documentID, partialHistory: true, extensions: [:],
                                isReadOnly: false, warnings: warnings)
    }

    // MARK: Escribir

    /// Captura una instantánea consistente —cursor, grafo, estado, contador y auxiliares de una misma generación— y
    /// la serializa con todos los objetos alcanzables. El resultado se vuelve a leer y validar antes de entregarlo:
    /// un guardado nunca produce un archivo que esta misma app no pueda abrir.
    static func snapshot(of document: PixelArtDocument, savedAt: Date = PxaDates.now(), writerVersion: String = "",
                         saveID: UUID = UUID()) throws -> Snapshot {
        guard document.isReadOnly == false else {
            throw PixelArtError.unsupported("guardado", "el archivo viene de una versión posterior: se abre solo en lectura")
        }
        guard document.core.history.currentState == document.core.stateRef else {
            throw PixelArtError.invalid("guardado", "el cursor del historial y el estado actual no coinciden")
        }
        var store = document.core.store
        let prepared = document.assistant.preparedForSave()
        let historyRef = PixelHistoryCodec.encode(document.core.history, into: &store)
        let editorRef = PixelEditorStateCodec.encode(document.editor, into: &store)
        let presetsRef = PixelExportPresetsCodec.encode(document.exportPresets, into: &store)
        let assistantRef = prepared.isEmpty ? nil : PixelAssistantCodec.encode(prepared, into: &store)
        var manifest = PxaManifest(documentID: document.documentID, saveID: saveID, createdAt: document.createdAt,
                                   savedAt: PxaDates.truncated(savedAt), writerVersion: writerVersion,
                                   currentState: document.core.stateRef, history: historyRef, editorState: editorRef,
                                   assistantState: assistantRef, exportPresets: presetsRef,
                                   nextPaletteEntryID: document.core.nextPaletteEntryID, objectCount: 0, uncompressedBytes: 0,
                                   copiedFrom: document.copiedFrom, partialHistory: document.partialHistory,
                                   extensions: document.extensions)
        let live = try store.reachable(from: manifest.roots)
        let pruned = store.pruned(keeping: live)
        manifest.objectCount = pruned.count
        manifest.uncompressedBytes = pruned.totalBytes
        var entries = [PxaZip.Entry(name: PxaZip.manifestName, data: manifest.data())]
        for hash in pruned.hashes.sorted() {
            entries.append(PxaZip.Entry(name: PxaZip.objectName(hash), data: pruned.objects[hash] ?? Data()))
        }
        if let preview = PixelArtPreview.png(of: document.state, frame: document.editor.activeFrameID) {
            entries.append(PxaZip.Entry(name: PxaZip.previewName, data: preview))
        }
        let data = try PxaZip.write(entries)
        _ = try read(data)
        let mark = PixelArtDocument.SavedMark(history: document.core.history, editor: document.editor, assistant: prepared,
                                              exportPresets: document.exportPresets, saveID: saveID)
        return Snapshot(data: data, manifest: manifest, mark: mark)
    }
}
