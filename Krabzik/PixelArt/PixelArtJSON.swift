import Foundation

/// JSON de los objetos `.pxa`. Se escribe en forma canónica —claves ordenadas por sus bytes UTF-8,
/// sin espacios— y se lee de forma estricta: sin BOM, sin claves duplicadas, sin comentarios, sin
/// números no finitos y con profundidad acotada (PXA-01 §1). Es un valor puro, seguro entre hilos.
enum PixelArtJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([PixelArtJSON])
    case object([String: PixelArtJSON])

    // MARK: Lectura estricta

    static func parse(_ data: Data, section: String, maxDepth: Int = PxaLimits.jsonDepth) throws -> PixelArtJSON {
        guard data.starts(with: [0xEF, 0xBB, 0xBF]) == false else {
            throw PixelArtError.invalid(section, "el JSON no admite BOM")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw PixelArtError.invalid(section, "el JSON no es UTF-8 válido")
        }
        var parser = Parser(bytes: [UInt8](data), section: section, maxDepth: maxDepth)
        let value = try parser.parseValue(depth: 1)
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw PixelArtError.invalid(section, "hay contenido después del valor JSON") }
        return value
    }

    // MARK: Escritura canónica

    func canonicalData() -> Data {
        var output: [UInt8] = []
        write(into: &output)
        return Data(output)
    }

    private func write(into output: inout [UInt8]) {
        switch self {
        case .null: output.append(contentsOf: Array("null".utf8))
        case .bool(let value): output.append(contentsOf: Array((value ? "true" : "false").utf8))
        case .int(let value): output.append(contentsOf: Array(String(value).utf8))
        case .double(let value): output.append(contentsOf: Array(String(value).utf8))
        case .string(let value): Self.writeString(value, into: &output)
        case .array(let items):
            output.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                item.write(into: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let fields):
            output.append(UInt8(ascii: "{"))
            let keys = fields.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (index, key) in keys.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                Self.writeString(key, into: &output)
                output.append(UInt8(ascii: ":"))
                fields[key]?.write(into: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ text: String, into output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""): output.append(contentsOf: Array("\\\"".utf8))
            case UInt8(ascii: "\\"): output.append(contentsOf: Array("\\\\".utf8))
            case 0x08: output.append(contentsOf: Array("\\b".utf8))
            case 0x0C: output.append(contentsOf: Array("\\f".utf8))
            case 0x0A: output.append(contentsOf: Array("\\n".utf8))
            case 0x0D: output.append(contentsOf: Array("\\r".utf8))
            case 0x09: output.append(contentsOf: Array("\\t".utf8))
            case 0..<0x20:
                let hex = String(byte, radix: 16)
                output.append(contentsOf: Array("\\u00\(hex.count == 1 ? "0" : "")\(hex)".utf8))
            default: output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }

    // MARK: Analizador

    private struct Parser {
        let bytes: [UInt8]
        let section: String
        let maxDepth: Int
        var position = 0

        init(bytes: [UInt8], section: String, maxDepth: Int) {
            self.bytes = bytes
            self.section = section
            self.maxDepth = maxDepth
        }

        var isAtEnd: Bool { position >= bytes.count }

        mutating func skipWhitespace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
        }

        private func fail(_ cause: String) -> PixelArtError {
            PixelArtError.invalid(section, "\(cause) (byte \(position))")
        }

        mutating func parseValue(depth: Int) throws -> PixelArtJSON {
            guard depth <= maxDepth else { throw PixelArtError.limit(section, "profundidad JSON superior a \(maxDepth)") }
            skipWhitespace()
            guard position < bytes.count else { throw fail("el JSON termina antes de tiempo") }
            switch bytes[position] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            default: return try parseNumber()
            }
        }

        private mutating func literal(_ word: String, _ value: PixelArtJSON) throws -> PixelArtJSON {
            let expected = Array(word.utf8)
            guard position + expected.count <= bytes.count, Array(bytes[position..<position + expected.count]) == expected else {
                throw fail("valor desconocido")
            }
            position += expected.count
            return value
        }

        private mutating func parseObject(depth: Int) throws -> PixelArtJSON {
            position += 1
            var fields: [String: PixelArtJSON] = [:]
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
                position += 1
                return .object(fields)
            }
            while true {
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw fail("se esperaba una clave") }
                let key = try parseString()
                guard fields[key] == nil else { throw PixelArtError.invalid(section, "clave duplicada «\(key)»") }
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw fail("falta «:»") }
                position += 1
                fields[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard position < bytes.count else { throw fail("el objeto no se cierra") }
                if bytes[position] == UInt8(ascii: ",") {
                    position += 1
                    continue
                }
                guard bytes[position] == UInt8(ascii: "}") else { throw fail("se esperaba «,» o «}»") }
                position += 1
                return .object(fields)
            }
        }

        private mutating func parseArray(depth: Int) throws -> PixelArtJSON {
            position += 1
            var items: [PixelArtJSON] = []
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
                position += 1
                return .array(items)
            }
            while true {
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard position < bytes.count else { throw fail("la lista no se cierra") }
                if bytes[position] == UInt8(ascii: ",") {
                    position += 1
                    continue
                }
                guard bytes[position] == UInt8(ascii: "]") else { throw fail("se esperaba «,» o «]»") }
                position += 1
                return .array(items)
            }
        }

        private mutating func parseString() throws -> String {
            position += 1
            var raw: [UInt8] = []
            while true {
                guard position < bytes.count else { throw fail("la cadena no se cierra") }
                let byte = bytes[position]
                position += 1
                if byte == UInt8(ascii: "\"") { break }
                guard byte >= 0x20 else { throw fail("control sin escapar dentro de una cadena") }
                guard byte == UInt8(ascii: "\\") else {
                    raw.append(byte)
                    continue
                }
                raw.append(contentsOf: try parseEscape())
            }
            guard let text = String(bytes: raw, encoding: .utf8) else { throw fail("cadena que no es UTF-8") }
            return text
        }

        private mutating func parseEscape() throws -> [UInt8] {
            guard position < bytes.count else { throw fail("escape incompleto") }
            let code = bytes[position]
            position += 1
            switch code {
            case UInt8(ascii: "\""): return [UInt8(ascii: "\"")]
            case UInt8(ascii: "\\"): return [UInt8(ascii: "\\")]
            case UInt8(ascii: "/"): return [UInt8(ascii: "/")]
            case UInt8(ascii: "b"): return [0x08]
            case UInt8(ascii: "f"): return [0x0C]
            case UInt8(ascii: "n"): return [0x0A]
            case UInt8(ascii: "r"): return [0x0D]
            case UInt8(ascii: "t"): return [0x09]
            case UInt8(ascii: "u"): return try parseUnicodeEscape()
            default: throw fail("escape desconocido")
            }
        }

        private mutating func hex4() throws -> UInt32 {
            guard position + 4 <= bytes.count else { throw fail("escape \\u incompleto") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = Character(UnicodeScalar(bytes[position])).hexDigitValue else { throw fail("escape \\u inválido") }
                value = value * 16 + UInt32(digit)
                position += 1
            }
            return value
        }

        private mutating func parseUnicodeEscape() throws -> [UInt8] {
            var scalarValue = try hex4()
            if (0xD800...0xDBFF).contains(scalarValue) {
                guard position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") else {
                    throw fail("sustituto UTF-16 sin pareja")
                }
                position += 2
                let low = try hex4()
                guard (0xDC00...0xDFFF).contains(low) else { throw fail("sustituto UTF-16 sin pareja") }
                scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00...0xDFFF).contains(scalarValue) {
                throw fail("sustituto UTF-16 sin pareja")
            }
            guard let scalar = UnicodeScalar(scalarValue) else { throw fail("escape \\u inválido") }
            return Array(String(Character(scalar)).utf8)
        }

        private mutating func parseNumber() throws -> PixelArtJSON {
            let start = position
            if position < bytes.count, bytes[position] == UInt8(ascii: "-") { position += 1 }
            let integerStart = position
            while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
            let integerDigits = position - integerStart
            guard integerDigits > 0, integerDigits == 1 || bytes[integerStart] != 48 else { throw fail("número inválido") }
            var isInteger = true
            if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
                isInteger = false
                position += 1
                let fractionStart = position
                while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
                guard position > fractionStart else { throw fail("número inválido") }
            }
            if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
                isInteger = false
                position += 1
                if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") { position += 1 }
                let exponentStart = position
                while position < bytes.count, (48...57).contains(bytes[position]) { position += 1 }
                guard position > exponentStart else { throw fail("número inválido") }
            }
            let text = String(decoding: bytes[start..<position], as: UTF8.self)
            if isInteger {
                guard let value = Int(text) else { throw PixelArtError.invalid(section, "entero fuera de rango «\(text)»") }
                return .int(value)
            }
            guard let value = Double(text), value.isFinite else { throw PixelArtError.invalid(section, "número no finito «\(text)»") }
            return .double(value)
        }
    }
}

/// Lector de los campos de un objeto JSON. Cada campo que se pide se marca como usado y
/// `finish()` rechaza los que sobran: en 1.0 los campos inesperados son un error (PXA-01 §8).
/// Se usa dentro de una sola función de decodificación; no se comparte entre hilos.
final class PixelArtFields {
    let section: String
    private var fields: [String: PixelArtJSON]
    private var consumed = Set<String>()

    init(_ value: PixelArtJSON, section: String) throws {
        guard case .object(let fields) = value else { throw PixelArtError.invalid(section, "se esperaba un objeto") }
        self.section = section
        self.fields = fields
    }

    private func take(_ key: String) -> PixelArtJSON? {
        consumed.insert(key)
        return fields[key]
    }

    private func required(_ key: String) throws -> PixelArtJSON {
        guard let value = take(key) else { throw PixelArtError.invalid(section, "falta el campo «\(key)»") }
        return value
    }

    func has(_ key: String) -> Bool { fields[key] != nil }

    func string(_ key: String) throws -> String {
        guard case .string(let value) = try required(key) else { throw PixelArtError.invalid(section, "«\(key)» debe ser texto") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = take(key), value != .null else { return nil }
        guard case .string(let text) = value else { throw PixelArtError.invalid(section, "«\(key)» debe ser texto") }
        return text
    }

    func int(_ key: String, in range: ClosedRange<Int>? = nil) throws -> Int {
        guard case .int(let value) = try required(key) else { throw PixelArtError.invalid(section, "«\(key)» debe ser un entero") }
        if let range, range.contains(value) == false {
            throw PixelArtError.limit(section, "«\(key)» fuera de rango (\(range.lowerBound)…\(range.upperBound))")
        }
        return value
    }

    func optionalInt(_ key: String, in range: ClosedRange<Int>? = nil) throws -> Int? {
        guard let value = take(key), value != .null else { return nil }
        guard case .int(let number) = value else { throw PixelArtError.invalid(section, "«\(key)» debe ser un entero") }
        if let range, range.contains(number) == false {
            throw PixelArtError.limit(section, "«\(key)» fuera de rango (\(range.lowerBound)…\(range.upperBound))")
        }
        return number
    }

    func bool(_ key: String) throws -> Bool {
        guard case .bool(let value) = try required(key) else { throw PixelArtError.invalid(section, "«\(key)» debe ser booleano") }
        return value
    }

    func uuid(_ key: String) throws -> UUID {
        let text = try string(key)
        guard let value = UUID(uuidString: text), value.uuidString.lowercased() == text.lowercased() else {
            throw PixelArtError.invalid(section, "«\(key)» no es un UUID")
        }
        return value
    }

    func optionalUUID(_ key: String) throws -> UUID? {
        guard let text = try optionalString(key) else { return nil }
        guard let value = UUID(uuidString: text) else { throw PixelArtError.invalid(section, "«\(key)» no es un UUID") }
        return value
    }

    func array(_ key: String) throws -> [PixelArtJSON] {
        guard case .array(let value) = try required(key) else { throw PixelArtError.invalid(section, "«\(key)» debe ser una lista") }
        return value
    }

    func object(_ key: String) throws -> [String: PixelArtJSON] {
        guard case .object(let value) = try required(key) else { throw PixelArtError.invalid(section, "«\(key)» debe ser un objeto") }
        return value
    }

    func optionalObject(_ key: String) throws -> [String: PixelArtJSON]? {
        guard let value = take(key), value != .null else { return nil }
        guard case .object(let fields) = value else { throw PixelArtError.invalid(section, "«\(key)» debe ser un objeto") }
        return fields
    }

    func raw(_ key: String) throws -> PixelArtJSON { try required(key) }

    func uuids(_ key: String) throws -> [UUID] {
        try array(key).map { item in
            guard case .string(let text) = item, let value = UUID(uuidString: text) else {
                throw PixelArtError.invalid(section, "«\(key)» contiene un UUID inválido")
            }
            return value
        }
    }

    func nested(_ key: String) throws -> PixelArtFields {
        try PixelArtFields(try required(key), section: "\(section).\(key)")
    }

    /// Falla si el objeto trae campos que el esquema no conoce.
    func finish() throws {
        let extra = Set(fields.keys).subtracting(consumed)
        guard extra.isEmpty else {
            throw PixelArtError.invalid(section, "campo inesperado «\(extra.sorted().first ?? "")»")
        }
    }
}
