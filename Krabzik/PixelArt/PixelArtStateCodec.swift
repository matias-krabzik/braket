import Foundation

/// Convierte un `PixelArtState` en objetos del almacén y de vuelta (PXA-01 §3–§4).
/// Codificar es determinista —mismo estado, mismos bytes, mismos hashes—, y decodificar valida todo:
/// no sustituye un bloque roto por vacío ni repara referencias.
enum PixelArtStateCodec {
    // MARK: Codificar

    static func encode(_ state: PixelArtState, into store: inout PxaObjectStore) -> PxaObjectRef {
        let layerRefs = state.layers.map { encode($0, into: &store).json }
        let frameRefs = state.frames.map { encode($0, into: &store).json }
        let palette = encode(state.palette, into: &store)
        let sequences = encode(state.sequences, into: &store)
        return store.put(.documentState, fields: [
            "width": .int(state.width), "height": .int(state.height), "colorSpace": .string("sRGB"),
            "layers": .array(layerRefs), "frames": .array(frameRefs),
            "palette": palette.json, "sequences": sequences.json
        ])
    }

    private static func encode(_ layer: PixelLayer, into store: inout PxaObjectStore) -> PxaObjectRef {
        store.put(.layer, fields: [
            "id": .string(layer.id.uuidString), "name": .string(layer.name), "visible": .bool(layer.visible),
            "locked": .bool(layer.locked), "alphaLocked": .bool(layer.alphaLocked), "opacity": .int(layer.opacity),
            "blendMode": .string("normal")
        ])
    }

    private static func encode(_ frame: PixelFrame, into store: inout PxaObjectStore) -> PxaObjectRef {
        var cels: [String: PixelArtJSON] = [:]
        for (layerID, cel) in frame.cels { cels[layerID.uuidString] = encode(cel, into: &store).json }
        return store.put(.frame, fields: ["id": .string(frame.id.uuidString), "duration": .int(frame.duration),
                                          "cels": .object(cels)])
    }

    private static func encode(_ cel: PixelCel, into store: inout PxaObjectStore) -> PxaObjectRef {
        var tiles: [String: PixelArtJSON] = [:]
        for (coord, tile) in cel.tiles { tiles[coord.key] = store.put(Data(tile.bytes), type: .pixelTile).json }
        return store.put(.cel, fields: ["tiles": .object(tiles)])
    }

    private static func encode(_ palette: PixelPalette, into store: inout PxaObjectStore) -> PxaObjectRef {
        let entries = palette.entries.sorted { $0.id < $1.id }.map { entry -> PixelArtJSON in
            var fields: [String: PixelArtJSON] = [
                "id": .int(Int(entry.id)), "color": .array(entry.color.bytes.map { .int(Int($0)) }), "locked": .bool(entry.locked)
            ]
            if entry.name.isEmpty == false { fields["name"] = .string(entry.name) }
            return .object(fields)
        }
        return store.put(.palette, fields: ["name": .string(palette.name),
                                            "order": .array(palette.entries.map { .int(Int($0.id)) }),
                                            "entries": .array(entries)])
    }

    private static func encode(_ sequences: [PixelSequence], into store: inout PxaObjectStore) -> PxaObjectRef {
        let items = sequences.map { sequence -> PixelArtJSON in
            .object(["id": .string(sequence.id.uuidString), "name": .string(sequence.name),
                     "frames": .array(sequence.frameIDs.map { .string($0.uuidString) }),
                     "playback": .string(sequence.playback.rawValue), "loop": .bool(sequence.loops)])
        }
        return store.put(.sequences, fields: ["items": .array(items)])
    }

    // MARK: Decodificar

    static func decode(_ ref: PxaObjectRef, from store: PxaObjectStore) throws -> PixelArtState {
        let fields = try store.fields(ref)
        let width = try fields.int("width", in: 1...PxaLimits.canvasAxis)
        let height = try fields.int("height", in: 1...PxaLimits.canvasAxis)
        guard try fields.string("colorSpace") == "sRGB" else {
            throw PixelArtError.unsupported(fields.section, "solo se admite el espacio de color sRGB")
        }
        let layerRefs = try fields.refs("layers", as: .layer)
        let frameRefs = try fields.refs("frames", as: .frame)
        let paletteRef = try fields.ref("palette", as: .palette)
        let sequencesRef = try fields.ref("sequences", as: .sequences)
        try fields.finish()
        guard layerRefs.count <= PxaLimits.layers, frameRefs.count <= PxaLimits.frames else {
            throw PixelArtError.limit(fields.section, "demasiadas capas o fotogramas")
        }
        let palette = try decodePalette(paletteRef, store: store)
        let context = TileContext(width: width, height: height, paletteIDs: palette.ids)
        var cache: [String: PixelTile] = [:]
        let state = PixelArtState(width: width, height: height,
                                  layers: try layerRefs.map { try decodeLayer($0, store: store) },
                                  frames: try frameRefs.map { try decodeFrame($0, store: store, context: context, cache: &cache) },
                                  palette: palette,
                                  sequences: try decodeSequences(sequencesRef, store: store))
        try state.validate(deepTiles: false)
        return state
    }

    private struct TileContext {
        var width: Int
        var height: Int
        var paletteIDs: Set<UInt32>
    }

    private static func decodeLayer(_ ref: PxaObjectRef, store: PxaObjectStore) throws -> PixelLayer {
        let fields = try store.fields(ref)
        let layer = PixelLayer(id: try fields.uuid("id"), name: try fields.string("name"), visible: try fields.bool("visible"),
                               locked: try fields.bool("locked"), alphaLocked: try fields.bool("alphaLocked"),
                               opacity: try fields.int("opacity", in: 0...255))
        guard try fields.string("blendMode") == "normal" else {
            throw PixelArtError.unsupported(fields.section, "solo se admite el modo de fusión normal")
        }
        try fields.finish()
        return layer
    }

    private static func decodeFrame(_ ref: PxaObjectRef, store: PxaObjectStore, context: TileContext,
                                    cache: inout [String: PixelTile]) throws -> PixelFrame {
        let fields = try store.fields(ref)
        let id = try fields.uuid("id")
        let duration = try fields.int("duration", in: PxaLimits.minDurationMS...PxaLimits.maxDurationMS)
        let celMap = try fields.object("cels")
        try fields.finish()
        guard celMap.count <= PxaLimits.layers else { throw PixelArtError.limit(fields.section, "demasiadas celdas") }
        var cels: [UUID: PixelCel] = [:]
        for (key, value) in celMap {
            guard let layerID = UUID(uuidString: key)
                else { throw PixelArtError.invalid(fields.section, "ID de capa inválido en una celda") }
            let celRef = try PxaObjectRef(json: value, section: "\(fields.section).cels", expecting: .cel)
            cels[layerID] = try decodeCel(celRef, store: store, context: context, cache: &cache)
        }
        return PixelFrame(id: id, duration: duration, cels: cels)
    }

    private static func decodeCel(_ ref: PxaObjectRef, store: PxaObjectStore, context: TileContext,
                                  cache: inout [String: PixelTile]) throws -> PixelCel {
        let fields = try store.fields(ref)
        let tileMap = try fields.object("tiles")
        try fields.finish()
        var tiles: [TileCoord: PixelTile] = [:]
        for (key, value) in tileMap {
            guard let coord = TileCoord(key: key) else { throw PixelArtError.invalid(fields.section,
                                                                                     "coordenada de bloque inválida «\(key)»") }
            let tileRef = try PxaObjectRef(json: value, section: "\(fields.section).tiles", expecting: .pixelTile)
            let maxX = (context.width + PxaTile.side - 1) / PxaTile.side
            let maxY = (context.height + PxaTile.side - 1) / PxaTile.side
            guard coord.x >= 0, coord.y >= 0, coord.x < maxX, coord.y < maxY else {
                throw PixelArtError.invalid(fields.section, "bloque \(key) fuera del lienzo")
            }
            // Un bloque interior se valida una vez por hash; uno de borde depende de su posición.
            let isEdge = (coord.x + 1) * PxaTile.side > context.width || (coord.y + 1) * PxaTile.side > context.height
            let cacheKey = "\(tileRef.hash)|\(isEdge ? key : "inner")"
            if let cached = cache[cacheKey] {
                tiles[coord] = cached
                continue
            }
            let tile = try PixelTile.validate(try store.data(tileRef), at: coord, width: context.width, height: context.height,
                                              paletteIDs: context.paletteIDs, section: "bloque \(tileRef.hash.prefix(8))")
            guard tile.isEmpty == false else { throw PixelArtError.invalid(fields.section, "bloque vacío en \(key)") }
            cache[cacheKey] = tile
            tiles[coord] = tile
        }
        return PixelCel(tiles: tiles)
    }

    private static func decodePalette(_ ref: PxaObjectRef, store: PxaObjectStore) throws -> PixelPalette {
        let fields = try store.fields(ref)
        let name = try fields.string("name")
        let order = try fields.array("order")
        let entryJSON = try fields.array("entries")
        try fields.finish()
        guard entryJSON.count <= PxaLimits.paletteEntries, order.count == entryJSON.count else {
            throw PixelArtError.invalid(fields.section, "el orden y las entradas no coinciden o superan \(PxaLimits.paletteEntries)")
        }
        var byID: [UInt32: PaletteEntry] = [:]
        for item in entryJSON {
            let entry = try PixelArtFields(item, section: "\(fields.section).entries")
            let id = try entry.int("id", in: 1...Int(PxaLimits.paletteEntryIDMax))
            let channels = try entry.array("color").map { value -> UInt8 in
                guard case .int(let number) = value, (0...255).contains(number) else {
                    throw PixelArtError.invalid(fields.section, "canal de color fuera de 0–255")
                }
                return UInt8(number)
            }
            guard let color = PixelRGBA(bytes: channels) else { throw PixelArtError.invalid(fields.section, "un color necesita 4 canales") }
            let parsed = PaletteEntry(id: UInt32(id), name: try entry.optionalString("name") ?? "", color: color,
                                      locked: try entry.bool("locked"))
            try entry.finish()
            guard byID.updateValue(parsed, forKey: parsed.id) == nil else {
                throw PixelArtError.invalid(fields.section, "ID de entrada repetido \(id)")
            }
        }
        let ordered = try order.map { item -> PaletteEntry in
            guard case .int(let id) = item, let entry = byID[UInt32(truncatingIfNeeded: id)], id >= 1 else {
                throw PixelArtError.invalid(fields.section, "el orden menciona un ID inexistente")
            }
            return entry
        }
        guard Set(ordered.map(\.id)).count == ordered.count else {
            throw PixelArtError.invalid(fields.section, "el orden repite un ID")
        }
        return PixelPalette(name: name, entries: ordered)
    }

    private static func decodeSequences(_ ref: PxaObjectRef, store: PxaObjectStore) throws -> [PixelSequence] {
        let fields = try store.fields(ref)
        let items = try fields.array("items")
        try fields.finish()
        guard items.count <= PxaLimits.sequences else { throw PixelArtError.limit(fields.section, "demasiadas secuencias") }
        return try items.map { item in
            let entry = try PixelArtFields(item, section: "\(fields.section).items")
            let playbackName = try entry.string("playback")
            guard let playback = PixelPlayback(rawValue: playbackName) else {
                throw PixelArtError.invalid(fields.section, "reproducción desconocida «\(playbackName)»")
            }
            let sequence = PixelSequence(id: try entry.uuid("id"), name: try entry.string("name"), frameIDs: try entry.uuids("frames"),
                                         playback: playback, loops: try entry.bool("loop"))
            try entry.finish()
            return sequence
        }
    }
}
