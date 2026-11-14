import Compression
import Foundation

/// Contenedor ZIP de un `.pxa` (PXA-01 §1): métodos Store o Deflate, sin cifrado ni multipartes,
/// ZIP64 solo para el número de entradas. Se lee desde memoria sin extraer nada a disco: los
/// nombres de entrada nunca se usan como ruta, y un ZIP con nombres fuera del contrato se rechaza.
enum PxaZip {
    struct Entry: Equatable, Sendable {
        var name: String
        var data: Data
    }

    private enum Signature {
        static let local: UInt32 = 0x0403_4B50
        static let central: UInt32 = 0x0201_4B50
        static let endOfDirectory: UInt32 = 0x0605_4B50
        static let zip64EndOfDirectory: UInt32 = 0x0606_4B50
        static let zip64Locator: UInt32 = 0x0706_4B50
    }

    private static let section = "contenedor ZIP"
    private static let fixedLocalHeader = 30
    private static let fixedCentralHeader = 46
    private static let endRecordSize = 22
    private static let maxCommentSize = 65_535
    private static let unsetOffset: UInt32 = 0xFFFF_FFFF
    private static let unsetCount: UInt16 = 0xFFFF
    /// Un objeto descomprimido nunca supera el mayor tope individual del formato.
    private static let maxEntryBytes = max(PxaLimits.jsonObjectBytes, PxaLimits.imageBytes)

    // MARK: Nombres permitidos

    static let manifestName = "manifest.json"
    static let previewName = "preview.png"
    static let objectPrefix = "objects/"

    static func objectName(_ hash: String) -> String { objectPrefix + hash }

    /// Solo existen tres formas de nombre; cualquier otra es una entrada fuera del contrato.
    static func validateName(_ name: String) throws {
        if name == manifestName || name == previewName { return }
        if name.hasPrefix(objectPrefix), PxaObjectRef.isValidHash(String(name.dropFirst(objectPrefix.count))) { return }
        if name.hasPrefix("/") { throw PixelArtError.invalid(section, "ruta absoluta «\(name)»") }
        if name.contains("..") { throw PixelArtError.invalid(section, "ruta con «..» en «\(name)»") }
        if name.contains("\\") { throw PixelArtError.invalid(section, "barra invertida en «\(name)»") }
        if name.hasSuffix("/") { throw PixelArtError.invalid(section, "directorio «\(name)»: solo se admiten archivos") }
        throw PixelArtError.invalid(section, "entrada no permitida «\(name)»")
    }

    // MARK: Lectura

    /// Lee y verifica todas las entradas. Ningún tamaño declarado se usa para reservar memoria
    /// antes de compararlo con los topes; el CRC y el tamaño real se comprueban al final.
    static func read(_ archive: Data) throws -> [Entry] {
        guard archive.count <= PxaLimits.archiveBytes else {
            throw PixelArtError.limit(section, "el archivo supera \(PxaLimits.archiveBytes) bytes")
        }
        let reader = ByteReader(archive)
        let directory = try locateDirectory(reader)
        let headers = try readCentralDirectory(reader, directory: directory)
        try checkBudget(headers)
        try checkNoOverlap(headers, directoryOffset: directory.offset)
        return try headers.map { header in Entry(name: header.name, data: try extract(header, reader: reader)) }
    }

    private struct Directory {
        var offset: Int
        var size: Int
        var count: Int
    }

    private struct Header {
        var name: String
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var size: Int
        var localOffset: Int
        var dataStart = 0
    }

    private static func locateDirectory(_ reader: ByteReader) throws -> Directory {
        guard reader.count >= endRecordSize else { throw PixelArtError.invalid(section, "no es un archivo ZIP") }
        let lowest = max(0, reader.count - endRecordSize - maxCommentSize)
        var position = reader.count - endRecordSize
        var found: Int?
        while position >= lowest {
            if try reader.u32(position) == Signature.endOfDirectory,
               try position + endRecordSize + Int(reader.u16(position + 20)) == reader.count {
                found = position
                break
            }
            position -= 1
        }
        guard let end = found else { throw PixelArtError.invalid(section, "no se encontró el final del directorio ZIP") }
        guard try reader.u16(end + 4) == 0, try reader.u16(end + 6) == 0 else {
            throw PixelArtError.unsupported(section, "los archivos ZIP en varias partes no se admiten")
        }
        let entriesHere = try reader.u16(end + 8)
        let entriesTotal = try reader.u16(end + 10)
        let size = try reader.u32(end + 12)
        let offset = try reader.u32(end + 16)
        guard entriesHere == entriesTotal else { throw PixelArtError.invalid(section, "directorio ZIP inconsistente") }
        if entriesTotal == unsetCount || size == unsetOffset || offset == unsetOffset {
            return try locateZip64Directory(reader, endOfDirectory: end)
        }
        return try validated(Directory(offset: Int(offset), size: Int(size), count: Int(entriesTotal)), total: reader.count, end: end)
    }

    private static func locateZip64Directory(_ reader: ByteReader, endOfDirectory end: Int) throws -> Directory {
        let locator = end - 20
        guard locator >= 0, try reader.u32(locator) == Signature.zip64Locator, try reader.u32(locator + 4) == 0,
              try reader.u32(locator + 16) == 1 else {
            throw PixelArtError.invalid(section, "falta el localizador ZIP64")
        }
        let record = try reader.u64(locator + 8)
        guard record <= UInt64(locator), try reader.u32(Int(record)) == Signature.zip64EndOfDirectory else {
            throw PixelArtError.invalid(section, "registro ZIP64 inválido")
        }
        let base = Int(record)
        guard try reader.u32(base + 16) == 0, try reader.u32(base + 20) == 0 else {
            throw PixelArtError.unsupported(section, "los archivos ZIP en varias partes no se admiten")
        }
        let here = try reader.u64(base + 24)
        let total = try reader.u64(base + 32)
        let size = try reader.u64(base + 40)
        let offset = try reader.u64(base + 48)
        guard here == total, total <= UInt64(PxaLimits.objects + 2), size <= UInt64(reader.count), offset <= UInt64(reader.count) else {
            throw PixelArtError.limit(section, "demasiadas entradas o directorio fuera del archivo")
        }
        return try validated(Directory(offset: Int(offset), size: Int(size), count: Int(total)), total: reader.count, end: base)
    }

    private static func validated(_ directory: Directory, total: Int, end: Int) throws -> Directory {
        guard directory.count <= PxaLimits.objects + 2 else {
            throw PixelArtError.limit(section, "más de \(PxaLimits.objects) objetos")
        }
        guard directory.offset >= 0, directory.size >= 0, directory.offset + directory.size <= end else {
            throw PixelArtError.invalid(section, "el directorio ZIP queda fuera del archivo")
        }
        return directory
    }

    private static func readCentralDirectory(_ reader: ByteReader, directory: Directory) throws -> [Header] {
        var headers: [Header] = []
        var names = Set<String>()
        var position = directory.offset
        for _ in 0..<directory.count {
            guard try reader.u32(position) == Signature.central
                else { throw PixelArtError.invalid(section, "entrada de directorio dañada") }
            var header = try centralHeader(reader, at: position)
            guard names.insert(header.name).inserted else { throw PixelArtError.invalid(section, "entrada duplicada «\(header.name)»") }
            header.dataStart = try localDataStart(reader, header: header)
            headers.append(header)
            let nameLength = try Int(reader.u16(position + 28))
            let extraLength = try Int(reader.u16(position + 30))
            let commentLength = try Int(reader.u16(position + 32))
            position += fixedCentralHeader + nameLength + extraLength + commentLength
            guard position <= directory.offset + directory.size else {
                throw PixelArtError.invalid(section, "el directorio ZIP se sale de su tamaño")
            }
        }
        guard position == directory.offset + directory.size
            else { throw PixelArtError.invalid(section, "sobran datos en el directorio ZIP") }
        return headers
    }

    private static func centralHeader(_ reader: ByteReader, at position: Int) throws -> Header {
        let madeBy = try reader.u16(position + 4)
        let flags = try reader.u16(position + 8)
        let method = try reader.u16(position + 10)
        let nameLength = try Int(reader.u16(position + 28))
        let disk = try reader.u16(position + 34)
        let attributes = try reader.u32(position + 38)
        guard flags & 0x0001 == 0, flags & 0x0040 == 0 else { throw PixelArtError.unsupported(section, "no se admiten entradas cifradas") }
        guard method == 0 || method == 8 else { throw PixelArtError.unsupported(section, "método de compresión \(method) no admitido") }
        guard disk == 0 else { throw PixelArtError.unsupported(section, "los archivos ZIP en varias partes no se admiten") }
        if madeBy >> 8 == 3 {
            let fileType = (attributes >> 16) & 0xF000
            guard fileType == 0 || fileType == 0x8000 else {
                throw PixelArtError.invalid(section, "enlaces o archivos especiales no se admiten")
            }
        }
        let rawName = try reader.bytes(position + fixedCentralHeader, nameLength)
        guard let name = String(data: rawName, encoding: .utf8) else { throw PixelArtError.invalid(section,
                                                                                                   "nombre de entrada que no es UTF-8") }
        try validateName(name)
        let compressed = try reader.u32(position + 20)
        let size = try reader.u32(position + 24)
        let localOffset = try reader.u32(position + 42)
        guard compressed != unsetOffset, size != unsetOffset, localOffset != unsetOffset else {
            throw PixelArtError.unsupported(section, "las entradas ZIP64 de más de 4 GiB no se admiten")
        }
        return Header(name: name, method: method, crc: try reader.u32(position + 16), compressedSize: Int(compressed),
                      size: Int(size), localOffset: Int(localOffset))
    }

    private static func localDataStart(_ reader: ByteReader, header: Header) throws -> Int {
        let position = header.localOffset
        guard try reader.u32(position) == Signature.local else {
            throw PixelArtError.invalid(section, "encabezado local dañado en «\(header.name)»")
        }
        let nameLength = try Int(reader.u16(position + 26))
        let extraLength = try Int(reader.u16(position + 28))
        let localName = try reader.bytes(position + fixedLocalHeader, nameLength)
        guard String(data: localName, encoding: .utf8) == header.name else {
            throw PixelArtError.invalid(section, "el nombre local no coincide con el directorio en «\(header.name)»")
        }
        return position + fixedLocalHeader + nameLength + extraLength
    }

    private static func checkBudget(_ headers: [Header]) throws {
        var compressed = 0
        var uncompressed = 0
        for header in headers {
            let limit = header.name == manifestName ? PxaLimits.manifestBytes : maxEntryBytes
            guard header.size <= limit else {
                throw PixelArtError.limit(section, "«\(header.name)» declara \(header.size) bytes, más que su tope de \(limit)")
            }
            guard header.method == 8 || header.compressedSize == header.size else {
                throw PixelArtError.invalid(section, "«\(header.name)» almacenada con tamaños distintos")
            }
            compressed += header.compressedSize
            uncompressed += header.size
        }
        guard compressed <= PxaLimits.archiveBytes, uncompressed <= PxaLimits.uncompressedBytes else {
            throw PixelArtError.limit(section, "el contenido supera \(PxaLimits.uncompressedBytes) bytes descomprimidos")
        }
    }

    /// Dos entradas que comparten bytes —o un dato que pisa el directorio— son la base de las bombas ZIP.
    private static func checkNoOverlap(_ headers: [Header], directoryOffset: Int) throws {
        var previousEnd = 0
        for header in headers.sorted(by: { $0.dataStart < $1.dataStart }) {
            guard header.dataStart >= previousEnd, header.dataStart + header.compressedSize <= directoryOffset else {
                throw PixelArtError.invalid(section, "las entradas se solapan entre sí o con el directorio")
            }
            previousEnd = header.dataStart + header.compressedSize
        }
    }

    private static func extract(_ header: Header, reader: ByteReader) throws -> Data {
        let stored = try reader.bytes(header.dataStart, header.compressedSize)
        let data = header.method == 0 ? stored : try inflate(stored, expected: header.size, name: header.name)
        guard data.count == header.size else {
            throw PixelArtError.integrity(section, "«\(header.name)» no mide lo que declara")
        }
        guard crc32(data) == header.crc else { throw PixelArtError.integrity(section, "CRC incorrecto en «\(header.name)»") }
        return data
    }

    private static func inflate(_ compressed: Data, expected: Int, name: String) throws -> Data {
        if expected == 0 {
            guard compressed.isEmpty || Array(compressed) == [0x03, 0x00] else {
                throw PixelArtError.integrity(section, "«\(name)» vacía con datos comprimidos")
            }
            return Data()
        }
        // Un byte de más permite distinguir «exacto» de «truncado al tope».
        let capacity = expected + 1
        var output = [UInt8](repeating: 0, count: capacity)
        let written = compressed.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&output, capacity, base, compressed.count, nil, COMPRESSION_ZLIB)
        }
        guard written == expected else { throw PixelArtError.integrity(section,
                                                                       "«\(name)» se descomprime a un tamaño distinto del declarado") }
        return Data(output[0..<written])
    }

    // MARK: Escritura

    /// Escribe un ZIP determinista: fecha fija, atributos fijos y el orden recibido. Cada entrada
    /// se comprime solo si eso la achica de verdad.
    static func write(_ entries: [Entry]) throws -> Data {
        var output = Data()
        var central = Data()
        guard entries.count <= PxaLimits.objects + 2 else { throw PixelArtError.limit(section, "demasiadas entradas") }
        var names = Set<String>()
        for entry in entries {
            try validateName(entry.name)
            guard names.insert(entry.name).inserted else { throw PixelArtError.invalid(section, "entrada duplicada «\(entry.name)»") }
            let packed = deflate(entry.data)
            let method: UInt16 = packed == nil ? 0 : 8
            let payload = packed ?? entry.data
            let nameBytes = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let localOffset = output.count
            output.append(localHeader(name: nameBytes, method: method, crc: crc, compressed: payload.count, size: entry.data.count))
            output.append(payload)
            central.append(centralHeader(name: nameBytes, method: method, crc: crc, compressed: payload.count,
                                         size: entry.data.count, localOffset: localOffset))
            guard output.count + central.count <= PxaLimits.archiveBytes else {
                throw PixelArtError.limit(section, "el archivo supera \(PxaLimits.archiveBytes) bytes")
            }
        }
        let directoryOffset = output.count
        output.append(central)
        output.append(endRecords(count: entries.count, directorySize: central.count, directoryOffset: directoryOffset))
        return output
    }

    private static func deflate(_ data: Data) -> Data? {
        guard data.count > 16 else { return nil }
        var output = [UInt8](repeating: 0, count: data.count)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&output, output.count, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0, written < data.count else { return nil }
        return Data(output[0..<written])
    }

    private static let fixedDate: UInt16 = 0x0021

    private static func localHeader(name: Data, method: UInt16, crc: UInt32, compressed: Int, size: Int) -> Data {
        var header = Data()
        header.append(le32: Signature.local)
        header.append(le16: 20)
        header.append(le16: 0x0800)
        header.append(le16: method)
        header.append(le16: 0)
        header.append(le16: fixedDate)
        header.append(le32: crc)
        header.append(le32: UInt32(compressed))
        header.append(le32: UInt32(size))
        header.append(le16: UInt16(name.count))
        header.append(le16: 0)
        header.append(name)
        return header
    }

    private static func centralHeader(name: Data, method: UInt16, crc: UInt32, compressed: Int, size: Int, localOffset: Int) -> Data {
        var header = Data()
        header.append(le32: Signature.central)
        header.append(le16: 0x0314)
        header.append(le16: 20)
        header.append(le16: 0x0800)
        header.append(le16: method)
        header.append(le16: 0)
        header.append(le16: fixedDate)
        header.append(le32: crc)
        header.append(le32: UInt32(compressed))
        header.append(le32: UInt32(size))
        header.append(le16: UInt16(name.count))
        header.append(le16: 0)
        header.append(le16: 0)
        header.append(le16: 0)
        header.append(le16: 0)
        header.append(le32: 0o100_644 << 16)
        header.append(le32: UInt32(localOffset))
        header.append(name)
        return header
    }

    private static func endRecords(count: Int, directorySize: Int, directoryOffset: Int) -> Data {
        var tail = Data()
        let needsZip64 = count >= Int(unsetCount)
        if needsZip64 {
            let recordOffset = directoryOffset + directorySize
            tail.append(le32: Signature.zip64EndOfDirectory)
            tail.append(le64: 44)
            tail.append(le16: 45)
            tail.append(le16: 45)
            tail.append(le32: 0)
            tail.append(le32: 0)
            tail.append(le64: UInt64(count))
            tail.append(le64: UInt64(count))
            tail.append(le64: UInt64(directorySize))
            tail.append(le64: UInt64(directoryOffset))
            tail.append(le32: Signature.zip64Locator)
            tail.append(le32: 0)
            tail.append(le64: UInt64(recordOffset))
            tail.append(le32: 1)
        }
        tail.append(le32: Signature.endOfDirectory)
        tail.append(le16: 0)
        tail.append(le16: 0)
        tail.append(le16: needsZip64 ? unsetCount : UInt16(count))
        tail.append(le16: needsZip64 ? unsetCount : UInt16(count))
        tail.append(le32: UInt32(directorySize))
        tail.append(le32: UInt32(directoryOffset))
        tail.append(le16: 0)
        return tail
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
        return ~value
    }
}

/// Lectura con límites: cada acceso comprueba que el rango exista, así que un ZIP truncado o
/// con offsets falsos falla con un error y no con un acceso fuera de rango.
private struct ByteReader {
    let data: Data
    var count: Int { data.count }

    init(_ data: Data) { self.data = data }

    func bytes(_ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else {
            throw PixelArtError.invalid("contenedor ZIP", "una lectura queda fuera del archivo")
        }
        let start = data.startIndex + offset
        return data[start..<start + length]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        let part = try bytes(offset, 2)
        return part.enumerated().reduce(0) { $0 | UInt16($1.element) << (8 * UInt16($1.offset)) }
    }

    func u32(_ offset: Int) throws -> UInt32 {
        let part = try bytes(offset, 4)
        return part.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    func u64(_ offset: Int) throws -> UInt64 {
        let part = try bytes(offset, 8)
        return part.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func append(le32 value: UInt32) {
        append(contentsOf: (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
    }

    mutating func append(le64 value: UInt64) {
        append(contentsOf: (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) })
    }
}
