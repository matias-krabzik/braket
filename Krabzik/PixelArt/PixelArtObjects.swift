import CryptoKit
import Foundation

/// Tipos de objeto que admite el formato 1.0 (PXA-01 §1). No hay tipos binarios arbitrarios.
enum PxaObjectType: String, CaseIterable, Sendable {
    case documentState, layer, frame, cel, palette, sequences, historyIndex, revision
    case editorState, assistantState, proposal, assistantRecord, exportPresets
    case pixelTile, selectionTile, assistantImage

    var isBinary: Bool { self == .pixelTile || self == .selectionTile || self == .assistantImage }
    static let version = 1
}

/// Referencia tipada a un objeto: tipo esperado, versión, hash SHA-256 y bytes descomprimidos.
/// El hash y el tamaño verifican integridad y deduplican; no acreditan autoría ni confianza.
struct PxaObjectRef: Hashable, Sendable {
    var type: PxaObjectType
    var hash: String
    var size: Int

    var json: PixelArtJSON {
        .object(["type": .string(type.rawValue), "version": .int(PxaObjectType.version),
                 "hash": .string(hash), "size": .int(size)])
    }

    static func isValidHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    init(type: PxaObjectType, hash: String, size: Int) {
        self.type = type
        self.hash = hash
        self.size = size
    }

    init(json: PixelArtJSON, section: String, expecting expected: PxaObjectType) throws {
        let fields = try PixelArtFields(json, section: section)
        let typeName = try fields.string("type")
        guard let type = PxaObjectType(rawValue: typeName) else {
            throw PixelArtError.invalid(section, "tipo de objeto desconocido «\(typeName)»")
        }
        guard type == expected else {
            throw PixelArtError.invalid(section, "se esperaba un objeto «\(expected.rawValue)» y la referencia dice «\(typeName)»")
        }
        guard try fields.int("version") == PxaObjectType.version else {
            throw PixelArtError.unsupported(section, "versión de objeto desconocida")
        }
        let hash = try fields.string("hash")
        guard Self.isValidHash(hash) else { throw PixelArtError.invalid(section, "hash inválido") }
        let size = try fields.int("size", in: 0...PxaLimits.jsonObjectBytes.advanced(by: PxaLimits.imageBytes))
        try fields.finish()
        self.init(type: type, hash: hash, size: size)
    }
}

extension PixelArtFields {
    func ref(_ key: String, as type: PxaObjectType) throws -> PxaObjectRef {
        try PxaObjectRef(json: try raw(key), section: "\(section).\(key)", expecting: type)
    }

    func optionalRef(_ key: String, as type: PxaObjectType) throws -> PxaObjectRef? {
        guard has(key), try raw(key) != .null else { return nil }
        return try ref(key, as: type)
    }

    func refs(_ key: String, as type: PxaObjectType) throws -> [PxaObjectRef] {
        try array(key).enumerated().map { index, item in
            try PxaObjectRef(json: item, section: "\(section).\(key)[\(index)]", expecting: type)
        }
    }
}

/// Almacén de objetos inmutables identificados por su hash. Los objetos iguales se comparten entre
/// revisiones, celdas y propuestas sin compartir mutabilidad: son bytes, no estructuras vivas.
/// Es un valor; confinarlo al actor que posee el documento.
struct PxaObjectStore: Sendable {
    private(set) var objects: [String: Data] = [:]

    init() {}

    init(objects: [String: Data]) { self.objects = objects }

    var count: Int { objects.count }
    var totalBytes: Int { objects.values.reduce(0) { $0 + $1.count } }
    var hashes: Set<String> { Set(objects.keys) }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Guarda bytes y devuelve su referencia. Guardar dos veces lo mismo no duplica nada.
    @discardableResult
    mutating func put(_ data: Data, type: PxaObjectType) -> PxaObjectRef {
        let hash = Self.hash(of: data)
        objects[hash] = data
        return PxaObjectRef(type: type, hash: hash, size: data.count)
    }

    /// Guarda un objeto JSON agregando `type` y `version` y lo escribe en forma canónica.
    @discardableResult
    mutating func put(_ type: PxaObjectType, fields: [String: PixelArtJSON]) -> PxaObjectRef {
        var complete = fields
        complete["type"] = .string(type.rawValue)
        complete["version"] = .int(PxaObjectType.version)
        return put(PixelArtJSON.object(complete).canonicalData(), type: type)
    }

    /// Bytes de una referencia, comprobando tamaño y hash contra lo recibido, nunca contra una reserialización.
    func data(_ ref: PxaObjectRef) throws -> Data {
        guard let data = objects[ref.hash] else {
            throw PixelArtError.integrity("objeto \(ref.hash.prefix(8))", "falta el objeto «\(ref.type.rawValue)»")
        }
        guard data.count == ref.size else {
            throw PixelArtError.integrity("objeto \(ref.hash.prefix(8))", "el tamaño no coincide con la referencia")
        }
        guard Self.hash(of: data) == ref.hash else {
            throw PixelArtError.integrity("objeto \(ref.hash.prefix(8))", "el hash no coincide con el contenido")
        }
        return data
    }

    /// Campos de un objeto JSON ya verificado, con `type` y `version` consumidos y comprobados.
    func fields(_ ref: PxaObjectRef) throws -> PixelArtFields {
        let section = "objeto «\(ref.type.rawValue)» \(ref.hash.prefix(8))"
        guard ref.type.isBinary == false else { throw PixelArtError.invalid(section, "es binario, no JSON") }
        let data = try data(ref)
        guard data.count <= PxaLimits.jsonObjectBytes else {
            throw PixelArtError.limit(section, "supera \(PxaLimits.jsonObjectBytes) bytes")
        }
        let fields = try PixelArtFields(try PixelArtJSON.parse(data, section: section), section: section)
        guard try fields.string("type") == ref.type.rawValue else {
            throw PixelArtError.invalid(section, "el tipo guardado no coincide con la referencia")
        }
        guard try fields.int("version") == PxaObjectType.version else {
            throw PixelArtError.unsupported(section, "versión de objeto desconocida")
        }
        return fields
    }

    /// Objetos que un objeto JSON referencia directamente: los diccionarios con exactamente los
    /// campos de una referencia tipada. La decodificación estricta es la que fija su validez.
    func children(of ref: PxaObjectRef) throws -> [PxaObjectRef] {
        guard ref.type.isBinary == false else { return [] }
        let json = try PixelArtJSON.parse(try data(ref), section: "objeto \(ref.hash.prefix(8))")
        var found: [PxaObjectRef] = []
        try Self.collectRefs(json, into: &found)
        return found
    }

    private static func collectRefs(_ json: PixelArtJSON, into found: inout [PxaObjectRef]) throws {
        switch json {
        case .array(let items):
            for item in items { try collectRefs(item, into: &found) }
        case .object(let fields):
            if Set(fields.keys) == ["type", "version", "hash", "size"],
               case .string(let typeName)? = fields["type"], let type = PxaObjectType(rawValue: typeName) {
                found.append(try PxaObjectRef(json: json, section: "referencia", expecting: type))
            } else {
                for value in fields.values { try collectRefs(value, into: &found) }
            }
        default:
            break
        }
    }

    /// Todo lo alcanzable desde las raíces, sin repetir. Lo demás es basura recolectable (PXA-02 §7).
    func reachable(from roots: [PxaObjectRef]) throws -> Set<String> {
        var seen = Set<String>()
        var pending = roots
        while let ref = pending.popLast() {
            guard seen.insert(ref.hash).inserted else { continue }
            pending.append(contentsOf: try children(of: ref))
        }
        return seen
    }

    func pruned(keeping hashes: Set<String>) -> PxaObjectStore {
        PxaObjectStore(objects: objects.filter { hashes.contains($0.key) })
    }
}
