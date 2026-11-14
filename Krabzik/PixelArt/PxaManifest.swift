import Foundation

/// Manifiesto de un `.pxa` (PXA-01 §2): identidad, versiones y las referencias raíz desde las que se
/// alcanza todo lo demás. Es un valor; se escribe en forma canónica y se lee de forma estricta.
struct PxaManifest: Equatable, Sendable {
    static let formatName = "braket.pixel-art"
    static let supportedMajor = 1
    static let supportedMinor = 0

    var formatMinor = PxaManifest.supportedMinor
    var requiredFeatures: [String] = []
    var documentID: UUID
    /// Cambia en cada guardado completo e identifica esa generación del archivo.
    var saveID: UUID
    var createdAt: Date
    var savedAt: Date
    var writerName = "Braket"
    var writerVersion = ""
    var currentState: PxaObjectRef
    var history: PxaObjectRef
    var editorState: PxaObjectRef
    var assistantState: PxaObjectRef?
    var exportPresets: PxaObjectRef
    /// Próximo ID de entrada de paleta. Es global al documento y no retrocede al deshacer.
    var nextPaletteEntryID: UInt32
    var objectCount: Int
    var uncompressedBytes: Int
    /// ID del documento del que esta copia derivó; es informativo y nunca fusiona sesiones.
    var copiedFrom: UUID?
    /// La historia de esta copia es parcial (PXA-02 §7).
    var partialHistory = false
    /// Extensiones opcionales preservadas sin interpretar; no pueden cambiar el significado artístico.
    var extensions: [String: PixelArtJSON] = [:]

    /// Una versión menor posterior se abre solo en lectura y nunca se vuelve a guardar desde aquí.
    var isReadOnly: Bool { formatMinor > Self.supportedMinor }

    var roots: [PxaObjectRef] {
        [currentState, history, editorState, exportPresets] + (assistantState.map { [$0] } ?? [])
    }

    // MARK: JSON

    func data() -> Data {
        var fields: [String: PixelArtJSON] = [
            "format": .string(Self.formatName),
            "formatVersion": .object(["major": .int(Self.supportedMajor), "minor": .int(formatMinor)]),
            "requiredFeatures": .array(requiredFeatures.map { .string($0) }),
            "documentID": .string(documentID.uuidString), "saveID": .string(saveID.uuidString),
            "createdAt": .string(PxaDates.format(createdAt)), "savedAt": .string(PxaDates.format(savedAt)),
            "writer": .object(["name": .string(writerName), "version": .string(writerVersion)]),
            "currentState": currentState.json, "history": history.json, "editorState": editorState.json,
            "exportPresets": exportPresets.json, "nextPaletteEntryID": .int(Int(nextPaletteEntryID)),
            "objectCount": .int(objectCount), "uncompressedBytes": .int(uncompressedBytes)
        ]
        if let assistantState { fields["assistantState"] = assistantState.json }
        if let copiedFrom { fields["copiedFrom"] = .string(copiedFrom.uuidString) }
        if partialHistory { fields["partialHistory"] = .bool(true) }
        if extensions.isEmpty == false { fields["extensions"] = .object(extensions) }
        return PixelArtJSON.object(fields).canonicalData()
    }

    static func parse(_ data: Data) throws -> PxaManifest {
        let section = "manifiesto"
        guard data.count <= PxaLimits.manifestBytes else { throw PixelArtError.limit(section, "supera \(PxaLimits.manifestBytes) bytes") }
        let fields = try PixelArtFields(try PixelArtJSON.parse(data, section: section), section: section)
        guard try fields.string("format") == formatName else {
            throw PixelArtError.invalid(section, "no es un documento de pixel art de Braket")
        }
        let version = try fields.nested("formatVersion")
        let major = try version.int("major", in: 0...Int(Int32.max))
        let minor = try version.int("minor", in: 0...Int(Int32.max))
        try version.finish()
        guard major == supportedMajor else {
            throw PixelArtError.unsupported(section, "este archivo usa el formato \(major).\(minor); actualiza Braket para abrirlo")
        }
        let features = try fields.array("requiredFeatures").map { item -> String in
            guard case .string(let text) = item else { throw PixelArtError.invalid(section, "«requiredFeatures» debe contener texto") }
            return text
        }
        guard features.isEmpty || minor <= supportedMinor else {
            throw PixelArtError.unsupported(section,
                                            "el archivo exige capacidades que esta versión no conoce: \(features.joined(separator: ", "))")
        }
        guard features.isEmpty else {
            throw PixelArtError.unsupported(section,
                                            "el formato 1.0 no define capacidades obligatorias: \(features.joined(separator: ", "))")
        }
        let writer = try fields.nested("writer")
        let manifest = PxaManifest(formatMinor: minor, requiredFeatures: features,
                                   documentID: try fields.uuid("documentID"),
                                   saveID: try fields.uuid("saveID"),
                                   createdAt: try PxaDates.parse(try fields.string("createdAt"), section: section),
                                   savedAt: try PxaDates.parse(try fields.string("savedAt"), section: section),
                                   writerName: try writer.string("name"),
                                   writerVersion: try writer.string("version"),
                                   currentState: try fields.ref("currentState", as: .documentState),
                                   history: try fields.ref("history", as: .historyIndex),
                                   editorState: try fields.ref("editorState", as: .editorState),
                                   assistantState: try fields.optionalRef("assistantState", as: .assistantState),
                                   exportPresets: try fields.ref("exportPresets", as: .exportPresets),
                                   nextPaletteEntryID: UInt32(try fields.int("nextPaletteEntryID",
                                                                             in: 1...Int(PxaLimits.paletteCounterExhausted))),
                                   objectCount: try fields.int("objectCount", in: 0...PxaLimits.objects),
                                   uncompressedBytes: try fields.int("uncompressedBytes", in: 0...PxaLimits.uncompressedBytes),
                                   copiedFrom: try fields.optionalUUID("copiedFrom"),
                                   partialHistory: try fields.has("partialHistory") ? fields.bool("partialHistory") : false,
                                   extensions: try fields.optionalObject("extensions") ?? [:])
        try writer.finish()
        if minor <= supportedMinor { try fields.finish() }
        try PixelArtText.validateName(manifest.writerName, section: section, allowEmpty: true)
        return manifest
    }
}
