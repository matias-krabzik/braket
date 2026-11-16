import Foundation

/// Color de dibujo activo: un RGBA libre o una referencia de paleta (PXA-03 §2).
enum PixelDrawColor: Equatable, Sendable {
    case free(PixelRGBA)
    case linked(UInt32)
}

enum PixelSymmetry: String, Sendable, CaseIterable {
    case none, horizontal, vertical, both
}

/// Estado de edición que viaja con el archivo para poder continuar en otra sesión (PXA-01 §5): capa y
/// fotograma activos, selección, herramienta, color, pincel, vista. Anchos de paneles, tema, cuenta de
/// Codex y rutas son preferencias locales y no entran. No agrega revisiones: guardar el zoom no es historia.
/// El zoom y el centro se guardan como enteros (porcentaje y milésimas de píxel) para que el formato no
/// dependa de cómo se escriben los decimales.
struct PixelEditorState: Equatable, Sendable {
    var activeLayerID: UUID?
    var activeFrameID: UUID?
    var selectedLayerIDs: [UUID] = []
    var selectedFrameIDs: [UUID] = []
    var selection: PixelSelection?
    var tool = "pencil"
    var drawColor = PixelDrawColor.free(PixelRGBA(0, 0, 0))
    var brushSize = 1
    var symmetry = PixelSymmetry.none
    var showsGrid = false
    var onionSkin = false
    var onionPrevious = 2
    var onionNext = 1
    var zoomPercent = 800
    var centerX = 0
    var centerY = 0

    static let zoomRange = 1...25_600
    static let brushRange = 1...256
    static let centerRange = -(1 << 30)...(1 << 30)

    /// Estado inicial sobre la primera capa y el primer fotograma.
    static func initial(for state: PixelArtState) -> PixelEditorState {
        var editor = PixelEditorState()
        editor.activeLayerID = state.layers.first?.id
        editor.activeFrameID = state.frames.first?.id
        editor.centerX = state.width * 500
        editor.centerY = state.height * 500
        return editor
    }

    /// Ajusta referencias que ya no existen a entidades válidas. Devuelve `true` si hubo que corregir algo:
    /// con un archivo defectuoso se informa, y esto no autoriza reparar referencias artísticas.
    mutating func normalize(for state: PixelArtState) -> Bool {
        var adjusted = false
        let layerIDs = Set(state.layers.map(\.id))
        let frameIDs = Set(state.frames.map(\.id))
        if let id = activeLayerID, layerIDs.contains(id) == false {
            activeLayerID = state.layers.first?.id
            adjusted = true
        }
        if activeLayerID == nil {
            activeLayerID = state.layers.first?.id
            adjusted = true
        }
        if let id = activeFrameID, frameIDs.contains(id) == false {
            activeFrameID = state.frames.first?.id
            adjusted = true
        }
        if activeFrameID == nil {
            activeFrameID = state.frames.first?.id
            adjusted = true
        }
        let layers = selectedLayerIDs.filter(layerIDs.contains)
        let frames = selectedFrameIDs.filter(frameIDs.contains)
        if layers.count != selectedLayerIDs.count || frames.count != selectedFrameIDs.count { adjusted = true }
        selectedLayerIDs = layers
        selectedFrameIDs = frames
        if case .linked(let id) = drawColor, state.palette.entry(id) == nil {
            drawColor = .free(PixelRGBA(0, 0, 0))
            adjusted = true
        }
        if let selection, (try? selection.validateBounds(width: state.width, height: state.height, section: "selección")) == nil {
            self.selection = nil
            adjusted = true
        }
        centerX = min(max(centerX, 0), state.width * 1_000)
        centerY = min(max(centerY, 0), state.height * 1_000)
        return adjusted
    }
}

enum PixelEditorStateCodec {
    static func encode(_ editor: PixelEditorState, into store: inout PxaObjectStore) -> PxaObjectRef {
        var fields: [String: PixelArtJSON] = [
            "selectedLayerIDs": .array(editor.selectedLayerIDs.map { .string($0.uuidString) }),
            "selectedFrameIDs": .array(editor.selectedFrameIDs.map { .string($0.uuidString) }),
            "tool": .string(editor.tool), "brushSize": .int(editor.brushSize), "symmetry": .string(editor.symmetry.rawValue),
            "grid": .bool(editor.showsGrid), "onionSkin": .bool(editor.onionSkin), "zoomPercent": .int(editor.zoomPercent),
            "onionPrevious": .int(editor.onionPrevious), "onionNext": .int(editor.onionNext),
            "centerX": .int(editor.centerX), "centerY": .int(editor.centerY)
        ]
        switch editor.drawColor {
        case .free(let color): fields["drawColor"] = .object(["kind": .string("free"), "rgba": .array(color.bytes.map { .int(Int($0)) })])
        case .linked(let id): fields["drawColor"] = .object(["kind": .string("linked"), "id": .int(Int(id))])
        }
        if let layer = editor.activeLayerID { fields["activeLayerID"] = .string(layer.uuidString) }
        if let frame = editor.activeFrameID { fields["activeFrameID"] = .string(frame.uuidString) }
        if let selection = editor.selection { fields["selection"] = PixelFocusCodec.encode(selection, into: &store) }
        return store.put(.editorState, fields: fields)
    }

    static func decode(_ ref: PxaObjectRef, from store: PxaObjectStore) throws -> PixelEditorState {
        let fields = try store.fields(ref)
        var editor = PixelEditorState()
        editor.activeLayerID = try fields.optionalUUID("activeLayerID")
        editor.activeFrameID = try fields.optionalUUID("activeFrameID")
        editor.selectedLayerIDs = try fields.uuids("selectedLayerIDs")
        editor.selectedFrameIDs = try fields.uuids("selectedFrameIDs")
        guard editor.selectedLayerIDs.count <= PxaLimits.layers, editor.selectedFrameIDs.count <= PxaLimits.frames else {
            throw PixelArtError.limit(fields.section, "demasiados elementos seleccionados")
        }
        editor.tool = try fields.string("tool")
        try PixelArtText.validateName(editor.tool, section: fields.section)
        editor.brushSize = try fields.int("brushSize", in: PixelEditorState.brushRange)
        let symmetryName = try fields.string("symmetry")
        guard let symmetry = PixelSymmetry(rawValue: symmetryName) else {
            throw PixelArtError.invalid(fields.section, "simetría desconocida «\(symmetryName)»")
        }
        editor.symmetry = symmetry
        editor.showsGrid = try fields.bool("grid")
        editor.onionSkin = try fields.bool("onionSkin")
        if fields.has("onionPrevious") { editor.onionPrevious = try fields.int("onionPrevious", in: 0...2) }
        if fields.has("onionNext") { editor.onionNext = try fields.int("onionNext", in: 0...2) }
        editor.zoomPercent = try fields.int("zoomPercent", in: PixelEditorState.zoomRange)
        editor.centerX = try fields.int("centerX", in: PixelEditorState.centerRange)
        editor.centerY = try fields.int("centerY", in: PixelEditorState.centerRange)
        editor.drawColor = try decodeColor(try fields.raw("drawColor"), section: fields.section)
        if fields.has("selection") {
            editor.selection = try PixelFocusCodec.decode(try fields.raw("selection"), store: store, section: fields.section)
        }
        try fields.finish()
        return editor
    }

    private static func decodeColor(_ json: PixelArtJSON, section: String) throws -> PixelDrawColor {
        let color = try PixelArtFields(json, section: "\(section).drawColor")
        switch try color.string("kind") {
        case "free":
            let channels = try color.array("rgba").map { value -> UInt8 in
                guard case .int(let number) = value, (0...255).contains(number) else {
                    throw PixelArtError.invalid(section, "canal de color fuera de 0–255")
                }
                return UInt8(number)
            }
            guard let rgba = PixelRGBA(bytes: channels) else { throw PixelArtError.invalid(section, "un color necesita 4 canales") }
            try color.finish()
            return .free(rgba)
        case "linked":
            let id = try color.int("id", in: 1...Int(PxaLimits.paletteEntryIDMax))
            try color.finish()
            return .linked(UInt32(id))
        default:
            throw PixelArtError.invalid(section, "clase de color de dibujo desconocida")
        }
    }
}

/// Ajuste de exportación portátil: sin rutas absolutas. Al exportar se revalida que sus IDs existan.
struct PixelExportPreset: Equatable, Sendable {
    var id = UUID()
    var name: String
    var format: String
    var scale = 1
    var layerIDs: [UUID] = []
    var frameIDs: [UUID] = []
    var margin = 0
    var spacing = 0
    /// Nombre de archivo sin carpetas.
    var outputName: String

    static let formats: Set<String> = ["png", "gif", "spriteSheet"]

    func isUsable(in state: PixelArtState) -> Bool {
        Set(layerIDs).isSubset(of: state.layers.map(\.id)) && Set(frameIDs).isSubset(of: state.frames.map(\.id))
    }
}

enum PixelExportPresetsCodec {
    static func encode(_ presets: [PixelExportPreset], into store: inout PxaObjectStore) -> PxaObjectRef {
        let items = presets.map { preset -> PixelArtJSON in
            .object(["id": .string(preset.id.uuidString), "name": .string(preset.name), "format": .string(preset.format),
                     "scale": .int(preset.scale), "layers": .array(preset.layerIDs.map { .string($0.uuidString) }),
                     "frames": .array(preset.frameIDs.map { .string($0.uuidString) }), "margin": .int(preset.margin),
                     "spacing": .int(preset.spacing), "outputName": .string(preset.outputName)])
        }
        return store.put(.exportPresets, fields: ["presets": .array(items)])
    }

    static func decode(_ ref: PxaObjectRef, from store: PxaObjectStore) throws -> [PixelExportPreset] {
        let fields = try store.fields(ref)
        let items = try fields.array("presets")
        try fields.finish()
        guard items.count <= 256 else { throw PixelArtError.limit(fields.section, "demasiados ajustes de exportación") }
        return try items.map { item in
            let entry = try PixelArtFields(item, section: "\(fields.section).presets")
            let format = try entry.string("format")
            guard PixelExportPreset.formats.contains(format) else {
                throw PixelArtError.invalid(fields.section, "formato de exportación desconocido «\(format)»")
            }
            let outputName = try entry.string("outputName")
            guard outputName.contains("/") == false, outputName.contains("\\") == false, outputName != "..", outputName != "." else {
                throw PixelArtError.invalid(fields.section, "el nombre de salida no puede ser una ruta")
            }
            try PixelArtText.validateName(outputName, section: fields.section)
            let preset = PixelExportPreset(id: try entry.uuid("id"), name: try entry.string("name"), format: format,
                                           scale: try entry.int("scale", in: 1...64), layerIDs: try entry.uuids("layers"),
                                           frameIDs: try entry.uuids("frames"), margin: try entry.int("margin", in: 0...256),
                                           spacing: try entry.int("spacing", in: 0...256), outputName: outputName)
            try PixelArtText.validateName(preset.name, section: fields.section)
            try entry.finish()
            return preset
        }
    }
}
