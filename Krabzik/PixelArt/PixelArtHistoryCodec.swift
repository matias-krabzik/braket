import Foundation

/// Selección y foco como objetos del almacén (PXA-01 §5): cada bloque de máscara es un objeto binario
/// `selectionTile` y la selección es un mapa de coordenada de bloque a referencia.
enum PixelFocusCodec {
    static func encode(_ selection: PixelSelection, into store: inout PxaObjectStore) -> PixelArtJSON {
        var tiles: [String: PixelArtJSON] = [:]
        for (coord, tile) in selection.tiles where tile.isEmpty == false {
            tiles[coord.key] = store.put(Data(tile.bytes), type: .selectionTile).json
        }
        return .object(tiles)
    }

    static func decode(_ json: PixelArtJSON, store: PxaObjectStore, section: String) throws -> PixelSelection {
        guard case .object(let map) = json else { throw PixelArtError.invalid(section, "la selección debe ser un objeto") }
        guard map.count <= PxaLimits.tilesPerState else { throw PixelArtError.limit(section, "demasiados bloques de selección") }
        var selection = PixelSelection()
        for (key, value) in map {
            guard let coord = TileCoord(key: key), coord.x >= 0, coord.y >= 0 else {
                throw PixelArtError.invalid(section, "coordenada de selección inválida «\(key)»")
            }
            let ref = try PxaObjectRef(json: value, section: section, expecting: .selectionTile)
            let data = try store.data(ref)
            guard data.count == PxaTile.selectionByteCount else {
                throw PixelArtError.invalid(section, "una máscara mide \(PxaTile.selectionByteCount) bytes")
            }
            let tile = SelectionTile(bytes: [UInt8](data))
            guard tile.isEmpty == false else { throw PixelArtError.invalid(section, "máscara vacía guardada en \(key)") }
            selection.tiles[coord] = tile
        }
        return selection
    }

    static func encode(_ focus: PixelFocus, into store: inout PxaObjectStore) -> PixelArtJSON {
        var fields: [String: PixelArtJSON] = [:]
        if let layer = focus.layerID { fields["layerID"] = .string(layer.uuidString) }
        if let frame = focus.frameID { fields["frameID"] = .string(frame.uuidString) }
        if let selection = focus.selection { fields["selection"] = encode(selection, into: &store) }
        return .object(fields)
    }

    static func decode(_ json: PixelArtJSON, store: PxaObjectStore, section: String) throws -> PixelFocus {
        let fields = try PixelArtFields(json, section: section)
        var focus = PixelFocus(layerID: try fields.optionalUUID("layerID"), frameID: try fields.optionalUUID("frameID"))
        if fields.has("selection") { focus.selection = try decode(try fields.raw("selection"), store: store, section: section) }
        try fields.finish()
        return focus
    }
}

extension PixelSelection {
    /// La selección debe caer dentro del lienzo de su estado.
    func validateBounds(width: Int, height: Int, section: String) throws {
        for (coord, tile) in tiles {
            _ = try SelectionTile.validate(Data(tile.bytes), at: coord, width: width, height: height, section: section)
        }
    }
}

/// Revisiones y su índice como objetos (PXA-02 §1).
enum PixelHistoryCodec {
    static func encode(_ history: PixelHistory, into store: inout PxaObjectStore) -> PxaObjectRef {
        let ordered = history.revisions.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let entries = ordered.map { revision -> PixelArtJSON in
            .object(["id": .string(revision.id.uuidString), "ref": encode(revision, into: &store).json])
        }
        var preferred: [String: PixelArtJSON] = [:]
        for (parent, child) in history.preferredChild { preferred[parent.uuidString] = .string(child.uuidString) }
        let marks = history.bookmarks
            .map { PixelArtJSON.object(["revisionID": .string($0.revisionID.uuidString), "name": .string($0.name)]) }
        return store.put(.historyIndex, fields: [
            "rootRevisionID": .string(history.rootID.uuidString), "cursorRevisionID": .string(history.cursorID.uuidString),
            "revisions": .array(entries), "preferredChild": .object(preferred), "bookmarks": .array(marks)
        ])
    }

    static func encode(_ revision: PixelRevision, into store: inout PxaObjectStore) -> PxaObjectRef {
        var fields: [String: PixelArtJSON] = [
            "id": .string(revision.id.uuidString), "afterState": revision.afterState.json,
            "operationKind": .string(revision.operationKind), "operationVersion": .int(revision.operationVersion),
            "label": .string(revision.label), "source": .string(revision.source.rawValue),
            "createdAt": .string(PxaDates.format(revision.createdAt)), "affected": encode(revision.affected),
            "focusBefore": PixelFocusCodec.encode(revision.focusBefore, into: &store),
            "focusAfter": PixelFocusCodec.encode(revision.focusAfter, into: &store)
        ]
        if let parent = revision.parentID { fields["parentID"] = .string(parent.uuidString) }
        if let before = revision.beforeState { fields["beforeState"] = before.json }
        if let record = revision.assistantRecord { fields["assistantRecord"] = record.json }
        return store.put(.revision, fields: fields)
    }

    private static func encode(_ affected: PixelAffected) -> PixelArtJSON {
        .object([
            "layers": .array(affected.layers.map { .string($0.uuidString) }),
            "frames": .array(affected.frames.map { .string($0.uuidString) }),
            "paletteEntries": .array(affected.paletteEntries.map { .int(Int($0)) }),
            "regions": .array(affected.regions.map { region in
                .object(["layerID": .string(region.layerID.uuidString), "frameID": .string(region.frameID.uuidString),
                         "x": .int(region.x), "y": .int(region.y), "width": .int(region.width), "height": .int(region.height)])
            })
        ])
    }

    // MARK: Decodificar

    static func decode(_ ref: PxaObjectRef, from store: PxaObjectStore) throws -> PixelHistory {
        let fields = try store.fields(ref)
        let rootID = try fields.uuid("rootRevisionID")
        let cursorID = try fields.uuid("cursorRevisionID")
        let entries = try fields.array("revisions")
        let preferredMap = try fields.object("preferredChild")
        let markJSON = try fields.array("bookmarks")
        try fields.finish()
        guard entries.count <= PxaLimits.revisions else {
            throw PixelArtError.limit(fields.section, "más de \(PxaLimits.revisions) revisiones")
        }
        var revisions: [PixelRevision] = []
        revisions.reserveCapacity(entries.count)
        for item in entries {
            let entry = try PixelArtFields(item, section: "\(fields.section).revisions")
            let id = try entry.uuid("id")
            let revision = try decodeRevision(try entry.ref("ref", as: .revision), store: store)
            try entry.finish()
            guard revision.id == id else { throw PixelArtError.invalid(fields.section, "el ID del índice no coincide con la revisión") }
            revisions.append(revision)
        }
        var preferred: [UUID: UUID] = [:]
        for (parentText, childValue) in preferredMap {
            guard let parent = UUID(uuidString: parentText), case .string(let childText) = childValue,
                  let child = UUID(uuidString: childText) else {
                throw PixelArtError.invalid(fields.section, "continuación preferida inválida")
            }
            preferred[parent] = child
        }
        let bookmarks = try markJSON.map { item -> PixelBookmark in
            let mark = try PixelArtFields(item, section: "\(fields.section).bookmarks")
            let value = PixelBookmark(revisionID: try mark.uuid("revisionID"), name: try mark.string("name"))
            try mark.finish()
            return value
        }
        return try PixelHistory(revisions: revisions, rootID: rootID, cursorID: cursorID, preferredChild: preferred, bookmarks: bookmarks)
    }

    static func decodeRevision(_ ref: PxaObjectRef, store: PxaObjectStore) throws -> PixelRevision {
        let fields = try store.fields(ref)
        let sourceName = try fields.string("source")
        guard let source = PixelRevisionSource(rawValue: sourceName) else {
            throw PixelArtError.invalid(fields.section, "origen de revisión desconocido «\(sourceName)»")
        }
        let revision = PixelRevision(id: try fields.uuid("id"), parentID: try fields.optionalUUID("parentID"),
                                     beforeState: try fields.optionalRef("beforeState", as: .documentState),
                                     afterState: try fields.ref("afterState", as: .documentState),
                                     operationKind: try fields.string("operationKind"),
                                     operationVersion: try fields.int("operationVersion", in: 1...Int(Int32.max)),
                                     label: try fields.string("label"),
                                     source: source,
                                     createdAt: try PxaDates.parse(try fields.string("createdAt"), section: fields.section),
                                     affected: try decodeAffected(try fields.raw("affected"), section: fields.section),
                                     assistantRecord: try fields.optionalRef("assistantRecord", as: .assistantRecord),
                                     focusBefore: try PixelFocusCodec.decode(try fields.raw("focusBefore"), store: store,
                                                                             section: fields.section),
                                     focusAfter: try PixelFocusCodec.decode(try fields.raw("focusAfter"), store: store,
                                                                            section: fields.section))
        try fields.finish()
        return revision
    }

    private static func decodeAffected(_ json: PixelArtJSON, section: String) throws -> PixelAffected {
        let fields = try PixelArtFields(json, section: "\(section).affected")
        let entries = try fields.array("paletteEntries").map { value -> UInt32 in
            guard case .int(let number) = value, (1...Int(PxaLimits.paletteEntryIDMax)).contains(number) else {
                throw PixelArtError.invalid(section, "ID de paleta afectado inválido")
            }
            return UInt32(number)
        }
        let regions = try fields.array("regions").map { item -> PixelRegion in
            let region = try PixelArtFields(item, section: "\(section).regions")
            let value = PixelRegion(layerID: try region.uuid("layerID"), frameID: try region.uuid("frameID"),
                                    x: try region.int("x", in: 0...PxaLimits.canvasAxis), y: try region.int("y",
                                                                                                            in: 0...PxaLimits.canvasAxis),
                                    width: try region.int("width", in: 0...PxaLimits.canvasAxis),
                                    height: try region.int("height", in: 0...PxaLimits.canvasAxis))
            try region.finish()
            return value
        }
        let affected = PixelAffected(layers: try fields.uuids("layers"), frames: try fields.uuids("frames"),
                                     paletteEntries: entries, regions: regions)
        try fields.finish()
        return affected
    }
}
