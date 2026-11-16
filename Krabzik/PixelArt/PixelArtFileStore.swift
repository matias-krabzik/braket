import CryptoKit
import Darwin
import Foundation

/// Huella del contenido de un archivo: tamaño y SHA-256. Tamaño y fecha solos no bastan para detectar que otro
/// programa cambió el archivo (PXA-01 §7).
struct PixelArtFileFingerprint: Equatable, Codable, Sendable {
    var size: Int
    var sha256: String

    init(size: Int, sha256: String) {
        self.size = size
        self.sha256 = sha256
    }

    init(of data: Data) {
        size = data.count
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Fases del guardado, para simular un fallo en cada una en las pruebas.
enum PixelArtSavePhase: Sendable, CaseIterable {
    case writeTemporary, validateTemporary, synchronize, replace
}

/// Apertura y guardado de un `.pxa` en disco (PXA-01 §7). Guardar escribe un archivo temporal hermano en el mismo
/// volumen, lo valida y lo sincroniza, y solo entonces reemplaza el destino de forma atómica dentro de una sección
/// coordinada que compara la huella con la leída o guardada antes. Ante cualquier fallo, el destino anterior y el
/// estado en memoria quedan intactos. La atomicidad no garantiza durabilidad frente a cualquier fallo físico del disco.
enum PixelArtFileStore {
    struct Opened: Sendable {
        var document: PixelArtDocument
        var fingerprint: PixelArtFileFingerprint
    }

    private static let section = "archivo"

    /// Huella del archivo en `url`, o `nil` si no existe.
    static func fingerprint(of url: URL) throws -> PixelArtFileFingerprint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return PixelArtFileFingerprint(of: try Data(contentsOf: url))
    }

    /// Abre un archivo regular y lo valida por completo. Cancelar una apertura no toca el archivo.
    static func open(_ url: URL) throws -> Opened {
        try requireRegularFile(url)
        var data = Data()
        var readError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do {
                data = try Data(contentsOf: readable, options: .mappedIfSafe)
            } catch {
                readError = error
            }
        }
        if let failure = readError ?? coordinationError { throw failure }
        return Opened(document: try PixelArtFile.read(data), fingerprint: PixelArtFileFingerprint(of: data))
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw PixelArtError.invalid(section, "«\(url.lastPathComponent)» no es un archivo regular")
        }
    }

    /// Guarda la instantánea y devuelve la nueva huella. `expecting` es la huella que se leyó o guardó antes
    /// (`nil` si el archivo todavía no existe): si el disco ya no coincide, se rechaza con un conflicto y no se
    /// sobrescribe nada.
    @discardableResult
    static func save(_ snapshot: PixelArtFile.Snapshot, to url: URL, expecting: PixelArtFileFingerprint?,
                     hook: ((PixelArtSavePhase) throws -> Void)? = nil) throws -> PixelArtFileFingerprint {
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PixelArtError.invalid(section, "la carpeta de destino no existe")
        }
        if FileManager.default.fileExists(atPath: url.path) { try requireRegularFile(url) }
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try hook?(.writeTemporary)
        try snapshot.data.write(to: temporary, options: [])
        try hook?(.validateTemporary)
        let written = try Data(contentsOf: temporary)
        guard written == snapshot.data else { throw PixelArtError.integrity(section,
                                                                            "el archivo temporal no coincide con lo que se escribió") }
        _ = try PixelArtFile.read(written)
        try hook?(.synchronize)
        try synchronize(temporary)
        try hook?(.replace)
        try replace(url, with: temporary, expecting: expecting)
        return PixelArtFileFingerprint(of: snapshot.data)
    }

    private static func synchronize(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        // F_FULLFSYNC pide al disco vaciar su caché; no todos los sistemas de archivos lo admiten, y no es un error.
        _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
    }

    private static func replace(_ url: URL, with temporary: URL, expecting: PixelArtFileFingerprint?) throws {
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { destination in
            do {
                let current = try fingerprint(of: destination)
                guard current == expecting else {
                    throw PixelArtError(kind: .conflict, section: section,
                                        cause: "«\(url.lastPathComponent)» cambió fuera de Braket desde que se leyó o guardó")
                }
                if current == nil {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                } else {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                }
            } catch {
                failure = error
            }
        }
        if let error = failure ?? coordinationError { throw error }
    }
}
