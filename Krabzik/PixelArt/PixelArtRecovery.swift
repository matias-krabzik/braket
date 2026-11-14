import CryptoKit
import Foundation

/// Cuándo capturar una copia de recuperación (PXA-01 §7): 2 segundos sin cambios, o al menos cada 30 segundos de
/// edición continua si no hay otra escritura en curso. Es lógica pura: el planificador que la usa pone el reloj.
struct PixelAutosavePolicy: Equatable, Sendable {
    var quietInterval: TimeInterval = 2
    var maxInterval: TimeInterval = 30

    /// `firstChange` es el primer cambio no capturado todavía; `nil` si no hay nada pendiente.
    func shouldCapture(now: Date, lastChange: Date?, firstChange: Date?, isWriting: Bool) -> Bool {
        guard isWriting == false, let lastChange, let firstChange else { return false }
        return now.timeIntervalSince(lastChange) >= quietInterval || now.timeIntervalSince(firstChange) >= maxInterval
    }
}

/// Una copia de recuperación local de un documento. No reemplaza el archivo del usuario ni equivale a Guardar.
struct PixelArtRecoveryEntry: Equatable, Codable, Sendable {
    var key: String
    var sequence: Int
    var documentID: UUID
    var capturedAt: Date
    /// Huella del archivo original en el que se basaba; `nil` en un borrador que nunca se guardó.
    var baseFingerprint: PixelArtFileFingerprint?
    var contentFingerprint: PixelArtFileFingerprint
}

/// Recuperación local de documentos abiertos (PXA-01 §7). Conserva las dos últimas generaciones válidas por
/// documento y ubicación, y nunca recicla la anterior antes de verificar la nueva. No promete conservar un
/// trazo interrumpido antes de confirmar su transacción: lo que se guarda son revisiones completas.
struct PixelArtRecoveryStore: Sendable {
    let directory: URL
    static let generationsKept = 2

    init(directory: URL) { self.directory = directory }

    /// Clave estable de una ubicación: hash de su ruta canónica. Una copia hecha en Finder con el mismo
    /// documento-ID es otra ubicación, así que no se fusionan sesiones por el ID embebido.
    static func key(forLocation url: URL) -> String {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Un borrador sin ruta tiene identidad local propia y también es recuperable.
    static func draftKey(_ id: UUID) -> String { "draft-\(id.uuidString)" }

    private func folder(_ key: String) -> URL { directory.appendingPathComponent(key, isDirectory: true) }
    private func contentURL(_ key: String, _ sequence: Int) -> URL { folder(key).appendingPathComponent("\(sequence).pxa") }
    private func metaURL(_ key: String, _ sequence: Int) -> URL { folder(key).appendingPathComponent("\(sequence).json") }

    // MARK: Capturar

    /// Escribe una generación completa y consistente. La nueva se verifica antes de retirar la más vieja.
    @discardableResult
    func capture(_ snapshot: PixelArtFile.Snapshot, key: String, baseFingerprint: PixelArtFileFingerprint?,
                 at date: Date = Date()) throws -> PixelArtRecoveryEntry {
        try FileManager.default.createDirectory(at: folder(key), withIntermediateDirectories: true)
        let sequence = try nextSequence(forKey: key)
        let temporary = folder(key).appendingPathComponent(".\(sequence).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try snapshot.data.write(to: temporary)
        let written = try Data(contentsOf: temporary)
        guard written == snapshot.data else { throw PixelArtError.integrity("recuperación", "la copia escrita no coincide") }
        _ = try PixelArtFile.read(written)
        let entry = PixelArtRecoveryEntry(key: key, sequence: sequence, documentID: snapshot.manifest.documentID, capturedAt: date,
                                          baseFingerprint: baseFingerprint, contentFingerprint: PixelArtFileFingerprint(of: written))
        try FileManager.default.moveItem(at: temporary, to: contentURL(key, sequence))
        try JSONEncoder().encode(entry).write(to: metaURL(key, sequence))
        for stale in try entries(forKey: key).dropFirst(Self.generationsKept) { try remove(stale) }
        return entry
    }

    /// Siguiente número de generación, mirando todos los archivos —también los dañados— para no pisar ninguno.
    private func nextSequence(forKey key: String) throws -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder(key).path)) ?? []
        let numbers = names.compactMap { name -> Int? in
            guard name.hasSuffix(".pxa") || name.hasSuffix(".json") else { return nil }
            return Int(name.split(separator: ".").first ?? "")
        }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: Consultar

    /// Generaciones guardadas de una clave, de la más nueva a la más vieja. Una cuyo contenido ya no coincide con su
    /// huella se omite: no se ofrece una recuperación dañada como si fuera válida.
    func entries(forKey key: String) throws -> [PixelArtRecoveryEntry] {
        guard FileManager.default.fileExists(atPath: folder(key).path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder(key).path).filter { $0.hasSuffix(".json") }
        var found: [PixelArtRecoveryEntry] = []
        for name in names {
            guard let data = try? Data(contentsOf: folder(key).appendingPathComponent(name)),
                  let entry = try? JSONDecoder().decode(PixelArtRecoveryEntry.self, from: data),
                  let content = try? Data(contentsOf: contentURL(key, entry.sequence)),
                  PixelArtFileFingerprint(of: content) == entry.contentFingerprint else { continue }
            found.append(entry)
        }
        return found.sorted { $0.sequence > $1.sequence }
    }

    func load(_ entry: PixelArtRecoveryEntry) throws -> PixelArtDocument {
        try PixelArtFile.read(try Data(contentsOf: contentURL(entry.key, entry.sequence)))
    }

    /// Si el original cambió desde que se hizo la recuperación, se ofrece como copia separada y no como reemplazo.
    func conflictsWithOriginal(_ entry: PixelArtRecoveryEntry, current: PixelArtFileFingerprint?) -> Bool {
        entry.baseFingerprint != current
    }

    // MARK: Retirar

    /// Descartar elimina las recuperaciones de la clave, pero solo después de que el usuario lo confirmó.
    func discard(key: String) throws {
        guard FileManager.default.fileExists(atPath: folder(key).path) else { return }
        try FileManager.default.removeItem(at: folder(key))
    }

    /// Tras guardar correctamente, retira lo que ese guardado cubre: las generaciones hasta `sequence`.
    func retire(key: String, upTo sequence: Int) throws {
        for entry in try entries(forKey: key) where entry.sequence <= sequence { try remove(entry) }
    }

    private func remove(_ entry: PixelArtRecoveryEntry) throws {
        try? FileManager.default.removeItem(at: contentURL(entry.key, entry.sequence))
        try? FileManager.default.removeItem(at: metaURL(entry.key, entry.sequence))
    }
}
