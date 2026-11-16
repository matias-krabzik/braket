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

enum PixelArtRecoveryStatus: String, Codable, Sendable {
    /// Lo posee una sesión abierta.
    case active
    /// Quedó sin guardar ni descartar: se ofrece al iniciar.
    case pending
    /// El usuario lo descartó. Se registra antes de borrar, así una caída durante la limpieza no lo resucita.
    case discarded
}

enum PixelArtRecoveryContext: String, Codable, Sendable {
    case workspace
    case loosePixelArt
}

/// Qué tipo de cambio justifica la generación. Una captura que solo guarda la vista no es «trabajo perdido».
enum PixelArtChangeClass: String, Codable, Sendable {
    case content
    case viewOnly
}

/// Una generación capturada. Su nombre físico lo genera la app; nada que venga de un nombre visible lo determina.
struct PixelArtRecoverySnapshot: Equatable, Codable, Sendable {
    var generation: Int
    var fileName: String
    var byteCount: Int
    var sha256: String
    /// Informativa: el orden lo da la generación, no el reloj.
    var capturedAt: Date
    var changeClass: PixelArtChangeClass
    /// Sesión que escribió esta generación.
    var writer: UUID
    /// No se pudo demostrar que continúa la cadena del archivo actual: solo se recupera como copia.
    var independent: Bool
}

/// Índice versionado de un trabajo recuperable (PXA-08 §1). Es metadato local: no ejecuta rutas ni comandos.
struct PixelArtRecoveryRecord: Equatable, Codable, Sendable {
    var version: Int
    var recoveryID: UUID
    var owner: UUID
    var status: PixelArtRecoveryStatus
    var documentID: UUID
    var suggestedName: String
    /// Ruta original para comprobar el destino, nunca una instrucción de escritura.
    var originalPath: String?
    var context: PixelArtRecoveryContext
    var projectIdentity: String?
    var baseFingerprint: PixelArtFileFingerprint?
    var baseSaveID: UUID?
    /// De la generación más nueva a la más vieja.
    var snapshots: [PixelArtRecoverySnapshot]
    /// Última generación cubierta por un guardado explícito.
    var lastSavedGeneration: Int?
    var discardedAt: Date?

    var isDraft: Bool { originalPath == nil }

    /// Hay una generación con cambios de contenido sin guardar.
    var hasUnsavedContent: Bool {
        status != .discarded && snapshots.contains { $0.changeClass == .content }
    }
}

/// Fases de la publicación, para simular un corte en cada una en las pruebas.
enum PixelArtRecoveryPhase: Sendable, CaseIterable {
    case writeTemporary, verifyTemporary, publishSnapshot, writeIndex, retireOlder, removeFiles
}

/// Recuperación local (PXA-08). Cada trabajo tiene su `recoveryID` y su carpeta, un índice versionado y como máximo
/// dos generaciones válidas. Una generación nueva se verifica antes de retirar la más vieja, el índice se reemplaza de
/// forma atómica y un descarte se registra de forma durable antes de borrar. No promete conservar un trazo sin
/// confirmar: lo que se guarda son revisiones completas.
struct PixelArtRecoveryStore: Sendable {
    struct Problem: Equatable, Sendable {
        var folder: String
        var reason: String
    }

    struct Listing: Sendable {
        var records: [PixelArtRecoveryRecord] = []
        var problems: [Problem] = []
    }

    static let generationsKept = 2
    static let indexVersion = 1
    static let indexName = "index.json"
    static let maxIndexBytes = 1 << 20
    static let maxRecords = 10_000
    static let spaceMargin = 8 << 20
    private static let section = "recuperación"

    let directory: URL
    /// Se invoca al entrar en cada fase; lanzar un error simula un corte justo ahí.
    var faults: @Sendable (PixelArtRecoveryPhase) throws -> Void = { _ in }
    /// Espacio libre en el volumen del directorio, o `nil` si el sistema no lo informa.
    var availableCapacity: @Sendable (URL) -> Int64? = PixelArtRecoveryStore.systemAvailableCapacity

    init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/Braket/PixelArt/Recovery`, local a esta Mac.
    static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Braket", isDirectory: true)
            .appendingPathComponent("PixelArt", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }

    static let systemAvailableCapacity: @Sendable (URL) -> Int64? = { url in
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func indexURL(_ id: UUID) -> URL { folder(id).appendingPathComponent(Self.indexName) }

    // MARK: Crear y reclamar

    /// Abre un trabajo recuperable nuevo. Nunca se deduplica por documento-ID: dos copias hechas en Finder, o dos
    /// trabajos con el mismo nombre, tienen recuperaciones distintas.
    @discardableResult
    func begin(documentID: UUID, suggestedName: String, originalURL: URL?, context: PixelArtRecoveryContext,
               projectIdentity: String? = nil, base: PixelArtFileFingerprint?, baseSaveID: UUID? = nil, owner: UUID,
               recoveryID: UUID = UUID()) throws -> PixelArtRecoveryRecord {
        let record = PixelArtRecoveryRecord(version: Self.indexVersion, recoveryID: recoveryID, owner: owner, status: .active,
                                            documentID: documentID,
                                            suggestedName: suggestedName, originalPath: originalURL?.standardizedFileURL.path,
                                            context: context,
                                            projectIdentity: projectIdentity, baseFingerprint: base, baseSaveID: baseSaveID, snapshots: [],
                                            lastSavedGeneration: nil, discardedAt: nil)
        try Self.validate(record, expectedID: recoveryID)
        try ensureDirectory(directory)
        try ensureDirectory(folder(recoveryID))
        try writeIndex(record, phase: nil)
        return record
    }

    /// Una sesión nueva reclama el registro con un propietario nuevo. Un trabajo descartado no se reclama.
    @discardableResult
    func claim(_ id: UUID, newOwner: UUID) throws -> PixelArtRecoveryRecord {
        var record = try readRecord(id)
        guard record.status != .discarded else { throw Self.conflict("el trabajo ya se descartó") }
        record.owner = newOwner
        record.status = .active
        try writeIndex(record, phase: nil)
        return record
    }

    /// Al cerrar sin guardar ni descartar, el trabajo queda pendiente para ofrecerlo al iniciar.
    func release(_ id: UUID, owner: UUID) throws {
        var record = try readRecord(id)
        guard record.owner == owner, record.status == .active else { return }
        record.status = .pending
        try writeIndex(record, phase: nil)
    }

    /// Cambio de ubicación confirmado: conserva el `recoveryID` y solo actualiza la asociación.
    func relocate(_ id: UUID, to url: URL?, owner: UUID) throws {
        var record = try readRecord(id)
        try requireOwner(record, owner)
        record.originalPath = url?.standardizedFileURL.path
        try Self.validate(record, expectedID: id)
        try writeIndex(record, phase: nil)
    }

    // MARK: Capturar

    /// Escribe una generación completa y consistente: temporal propio → verificación → nombre único → índice → recién
    /// entonces se retira la más vieja. Un corte entre pasos deja disponibles las generaciones anteriores.
    @discardableResult
    func capture(_ snapshot: PixelArtFile.Snapshot, recoveryID: UUID, owner: UUID, generation: Int,
                 changeClass: PixelArtChangeClass, at date: Date = Date()) throws -> PixelArtRecoverySnapshot {
        var record = try readRecord(recoveryID)
        guard record.status != .discarded else { throw Self.conflict("el trabajo ya se descartó") }
        try requireOwner(record, owner)
        let floor = max(record.snapshots.first?.generation ?? 0, record.lastSavedGeneration ?? 0)
        guard generation > floor else {
            throw PixelArtError(kind: .stale, section: Self.section, cause: "la generación \(generation) no supera la \(floor)")
        }
        try requireSpace(for: snapshot.data.count)
        let name = "g\(generation)-\(UUID().uuidString).pxa"
        let temporary = folder(recoveryID).appendingPathComponent(".\(name).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try faults(.writeTemporary)
        try Self.writePrivate(snapshot.data, to: temporary)
        try faults(.verifyTemporary)
        let written = try Data(contentsOf: temporary)
        guard written == snapshot.data else { throw PixelArtError.integrity(Self.section, "la copia escrita no coincide") }
        _ = try PixelArtFile.read(written)
        try faults(.publishSnapshot)
        try FileManager.default.moveItem(at: temporary, to: folder(recoveryID).appendingPathComponent(name))
        let fingerprint = PixelArtFileFingerprint(of: written)
        let entry = PixelArtRecoverySnapshot(generation: generation, fileName: name, byteCount: fingerprint.size,
                                             sha256: fingerprint.sha256, capturedAt: date, changeClass: changeClass,
                                             writer: owner, independent: false)
        record.snapshots.insert(entry, at: 0)
        try writeIndex(record, phase: .writeIndex)
        if record.snapshots.count > Self.generationsKept {
            try faults(.retireOlder)
            let dropped = Array(record.snapshots.dropFirst(Self.generationsKept))
            record.snapshots = Array(record.snapshots.prefix(Self.generationsKept))
            try writeIndex(record, phase: nil)
            for old in dropped { try? FileManager.default.removeItem(at: folder(recoveryID).appendingPathComponent(old.fileName)) }
        }
        return entry
    }

    /// Falta de espacio: se conservan las generaciones válidas y se avisa; no se recorta nada para que quepa.
    private func requireSpace(for bytes: Int) throws {
        guard let free = availableCapacity(directory) else { return }
        guard free >= Int64(bytes) + Int64(Self.spaceMargin) else {
            throw PixelArtError(kind: .capacity, section: Self.section,
                                cause: "no hay espacio suficiente para actualizar la recuperación automática")
        }
    }

    // MARK: Consultar

    /// Lee y valida el índice de un trabajo. Un índice mal formado o de una versión que no se conoce se informa y no
    /// se borra.
    func readRecord(_ id: UUID) throws -> PixelArtRecoveryRecord {
        let url = indexURL(id)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw PixelArtError.invalid(Self.section, "falta el índice de la recuperación o no es un archivo regular")
        }
        guard let size = values?.fileSize, size <= Self.maxIndexBytes else {
            throw PixelArtError.limit(Self.section, "el índice supera \(Self.maxIndexBytes) bytes")
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: PixelArtRecoveryRecord
        do {
            record = try decoder.decode(PixelArtRecoveryRecord.self, from: data)
        } catch {
            throw PixelArtError.invalid(Self.section, "el índice no se puede leer")
        }
        guard record.version == Self.indexVersion else {
            throw PixelArtError.unsupported(Self.section, "versión de índice \(record.version) no admitida")
        }
        try Self.validate(record, expectedID: id)
        return record
    }

    /// Todos los trabajos no descartados. Una carpeta ilegible aparece como problema, nunca se elimina sola.
    func list() -> Listing {
        var listing = Listing()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return listing }
        for name in names.sorted() where name.hasPrefix(".") == false {
            if listing.records.count + listing.problems.count >= Self.maxRecords {
                listing.problems.append(Problem(folder: "…", reason: "hay más de \(Self.maxRecords) trabajos"))
                break
            }
            guard let id = UUID(uuidString: name) else {
                listing.problems.append(Problem(folder: name, reason: "el nombre no es un identificador de recuperación"))
                continue
            }
            do {
                let record = try readRecord(id)
                if record.status != .discarded { listing.records.append(record) }
            } catch {
                listing.problems.append(Problem(folder: name, reason: (error as? PixelArtError)?.cause ?? "ilegible"))
            }
        }
        return listing
    }

    /// Generaciones cuyo contenido coincide con su huella, de la más nueva a la más vieja. Una dañada no se ofrece.
    func validSnapshots(of record: PixelArtRecoveryRecord) -> [PixelArtRecoverySnapshot] {
        record.snapshots.filter { snapshot in
            guard let url = try? snapshotURL(snapshot.fileName, of: record.recoveryID),
                  let fingerprint = try? Self.fingerprint(ofFileAt: url) else { return false }
            return fingerprint.size == snapshot.byteCount && fingerprint.sha256 == snapshot.sha256
        }
    }

    /// Resultado de abrir una generación: completa, o solo con el estado actual cuando falla únicamente la historia.
    enum Loaded {
        case full(PixelArtDocument)
        case withoutHistory(PixelArtDocument)

        var document: PixelArtDocument {
            switch self {
            case .full(let document), .withoutHistory(let document): document
            }
        }
    }

    /// Abre una generación con el mismo validador y los mismos presupuestos del formato. Si la historia está dañada y el
    /// estado actual es íntegro, ofrece una copia sin historial completo; nunca un lienzo vacío.
    func load(_ snapshot: PixelArtRecoverySnapshot, of id: UUID) throws -> Loaded {
        let url = try snapshotURL(snapshot.fileName, of: id)
        let data = try Self.readBounded(url)
        guard data.count == snapshot.byteCount, PixelArtFileFingerprint(of: data).sha256 == snapshot.sha256 else {
            throw PixelArtError.integrity(Self.section, "la generación \(snapshot.generation) no coincide con su huella")
        }
        do {
            return .full(try PixelArtFile.read(data))
        } catch let error as PixelArtError where error.kind == .integrity || error.kind == .invalid {
            return .withoutHistory(try PixelArtFile.recoveredCopy(from: data))
        }
    }

    // MARK: Guardado, descarte y limpieza

    /// Tras un guardado correcto: retira lo que cubre. Una generación posterior se conserva; si no se puede demostrar
    /// que la escribió la misma sesión, queda como candidata independiente y se recupera como copia.
    func markSaved(_ id: UUID, owner: UUID, throughGeneration generation: Int, newBase: PixelArtFileFingerprint,
                   saveID: UUID? = nil) throws {
        var record = try readRecord(id)
        try requireOwner(record, owner)
        let covered = record.snapshots.filter { $0.generation <= generation }
        var remaining = record.snapshots.filter { $0.generation > generation }
        for index in remaining.indices where remaining[index].writer != owner { remaining[index].independent = true }
        record.snapshots = remaining
        record.lastSavedGeneration = max(record.lastSavedGeneration ?? 0, generation)
        record.baseFingerprint = newBase
        record.baseSaveID = saveID
        try writeIndex(record, phase: nil)
        for old in covered { try? FileManager.default.removeItem(at: folder(id).appendingPathComponent(old.fileName)) }
    }

    /// Descarta un trabajo. Primero registra el descarte de forma durable y luego borra: si la app cae entre ambos
    /// pasos, el próximo inicio respeta el descarte. Si `generation` no es `nil` y hay una captura posterior (de una
    /// sesión que ya reemplazó a la anterior), no toca nada.
    func discard(_ id: UUID, owner: UUID? = nil, ifNothingNewerThan generation: Int? = nil, at date: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: folder(id).path) else { return }
        var record = try readRecord(id)
        if let owner { try requireOwner(record, owner) }
        if let generation, let newest = record.snapshots.first?.generation, newest > generation {
            throw Self.conflict("hay una captura posterior que este descarte no cubre")
        }
        if record.status != .discarded {
            record.status = .discarded
            record.discardedAt = date
            try writeIndex(record, phase: nil)
        }
        try faults(.removeFiles)
        try FileManager.default.removeItem(at: folder(id))
    }

    /// Completa limpiezas que se interrumpieron: borra solo carpetas cuyo índice válido dice «descartado».
    @discardableResult
    func purgeDiscarded() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var purged = 0
        for name in names {
            guard let id = UUID(uuidString: name), let record = try? readRecord(id), record.status == .discarded else { continue }
            if (try? FileManager.default.removeItem(at: folder(id))) != nil { purged += 1 }
        }
        return purged
    }

    /// Acción explícita del usuario sobre una carpeta que no se pudo leer; nunca se hace sola.
    func removeUnreadable(_ id: UUID) throws {
        guard (try? readRecord(id)) == nil else { throw Self.conflict("la recuperación se puede leer: usá Descartar") }
        try FileManager.default.removeItem(at: folder(id))
    }

    /// Archivos de la carpeta que el índice no referencia (un temporal o una generación sin publicar). No se ofrecen
    /// como recuperación completa; solo se pueden analizar mediante una acción explícita.
    func orphanFiles(of id: UUID) throws -> [String] {
        let record = try readRecord(id)
        let referenced = Set(record.snapshots.map(\.fileName)).union([Self.indexName])
        let names = try FileManager.default.contentsOfDirectory(atPath: folder(id).path)
        return names.filter { referenced.contains($0) == false && Self.isSnapshotName($0) }.sorted()
    }

    /// Abre un huérfano para inspeccionarlo, con el mismo validador y sin tocar la generación más nueva.
    func loadOrphan(_ name: String, of id: UUID) throws -> PixelArtDocument {
        let url = try snapshotURL(name, of: id)
        return try PixelArtFile.read(try Self.readBounded(url))
    }

    // MARK: Interno

    private func requireOwner(_ record: PixelArtRecoveryRecord, _ owner: UUID) throws {
        guard record.owner == owner else { throw Self.conflict("otra sesión posee esta recuperación") }
    }

    private static func conflict(_ cause: String) -> PixelArtError {
        PixelArtError(kind: .conflict, section: section, cause: cause)
    }

    /// Un nombre físico es `g<generación>-<UUID>.pxa`; ninguno puede salir de la carpeta del trabajo.
    static func isSnapshotName(_ name: String) -> Bool {
        guard name.hasPrefix("g"), name.hasSuffix(".pxa"), name.utf8.count <= 64 else { return false }
        let body = name.dropFirst().dropLast(4)
        let parts = body.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[0].isEmpty == false, parts[0].allSatisfy(\.isASCII), parts[0].allSatisfy(\.isNumber) else {
            return false
        }
        return UUID(uuidString: String(parts[1])) != nil
    }

    private func snapshotURL(_ name: String, of id: UUID) throws -> URL {
        guard Self.isSnapshotName(name) else {
            throw PixelArtError.invalid(Self.section, "nombre de generación no válido")
        }
        let url = folder(id).appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PixelArtError.invalid(Self.section, "la generación no es un archivo regular")
        }
        return url
    }

    static func validate(_ record: PixelArtRecoveryRecord, expectedID: UUID) throws {
        guard record.recoveryID == expectedID else { throw PixelArtError.invalid(section, "el índice no corresponde a su carpeta") }
        for text in [record.suggestedName, record.originalPath ?? "", record.projectIdentity ?? ""] {
            guard text.utf8.count <= 4_096, text.unicodeScalars.contains(where: { $0.value == 0 }) == false else {
                throw PixelArtError.invalid(section, "un texto del índice es demasiado largo o contiene un carácter nulo")
            }
        }
        guard record.snapshots.count <= generationsKept + 1 else {
            throw PixelArtError.limit(section, "el índice referencia demasiadas generaciones")
        }
        var previous = Int.max
        for snapshot in record.snapshots {
            guard isSnapshotName(snapshot.fileName), snapshot.generation >= 1, snapshot.generation < previous,
                  snapshot.byteCount >= 0, snapshot.byteCount <= PxaLimits.archiveBytes,
                  PxaObjectRef.isValidHash(snapshot.sha256) else {
                throw PixelArtError.invalid(section, "una generación del índice no es válida o no está en orden")
            }
            previous = snapshot.generation
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// El índice se reemplaza de forma atómica: temporal propio, sincronizado, renombrado sobre el anterior.
    private func writeIndex(_ record: PixelArtRecoveryRecord, phase: PixelArtRecoveryPhase?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let temporary = folder(record.recoveryID).appendingPathComponent(".index.\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Self.writePrivate(data, to: temporary)
        if let phase { try faults(phase) }
        guard rename(temporary.path, indexURL(record.recoveryID).path) == 0 else {
            throw PixelArtError.integrity(Self.section, "no se pudo reemplazar el índice (\(errno))")
        }
    }

    /// Archivo privado (0600), escrito y sincronizado con el disco.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PixelArtError.integrity(section, "no se pudo crear un archivo temporal")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// Lee un archivo comprobando antes que no supere el tope del formato.
    private static func readBounded(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= PxaLimits.archiveBytes else {
            throw PixelArtError.limit(section, "la generación supera \(PxaLimits.archiveBytes) bytes")
        }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// Huella leída en bloques: no carga el archivo entero en memoria.
    static func fingerprint(ofFileAt url: URL) throws -> PixelArtFileFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 1 << 20), chunk.isEmpty == false {
            hasher.update(data: chunk)
            total += chunk.count
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return PixelArtFileFingerprint(size: total, sha256: digest)
    }
}
