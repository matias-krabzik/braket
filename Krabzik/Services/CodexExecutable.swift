import CryptoKit
import Foundation
import Security

/// Identidad de un binario: la ruta y el **contenido**. El contenido es lo único que
/// quien reemplaza el archivo no puede falsificar. El tamaño se puede igualar, y `mtime`
/// e inode los controla quien escribe: sobrescribir en el lugar conserva el inode, y
/// `mtime` se fija con `touch`. Leer el archivo entero cuesta ~10 ms cada 20 MB, una vez
/// por conexión, así que la identidad barata no se justificaba.
struct BinaryIdentity: Codable, Equatable, Sendable {
    let path: String
    let size: Int64
    /// SHA-256 del contenido, en hexadecimal.
    let digest: String

    /// Prefijo para mostrar en el diálogo de aprobación.
    var shortDigest: String { String(digest.prefix(16)) }
}

/// Estado de firma. **No se rechaza por ser ad hoc**: el `codex` de Homebrew suele
/// estarlo y rechazarlo rompería el caso más común. Se usa para informar. Lo que sí
/// se rechaza es `invalid`: dice estar firmado y no valida, o sea fue alterado.
enum CodexSignature: Equatable, Sendable {
    case developerID(team: String)
    case appleSigned
    case adHoc
    case unsigned
    case invalid

    var label: String {
        switch self {
        case .developerID(let team): return "firmado por Developer ID (equipo \(team))"
        case .appleSigned: return "firmado por Apple"
        case .adHoc: return "firma ad hoc, sin Developer ID"
        case .unsigned: return "sin firma"
        case .invalid: return "firma inválida: el binario fue alterado"
        }
    }

    var isOfferable: Bool { self != .invalid }
}

/// Un ejecutable de Codex que pasó los rechazos y se le puede ofrecer al usuario,
/// con su firma y su identidad para que vea qué va a aprobar.
struct CodexCandidate: Equatable, Sendable {
    let url: URL
    let signature: CodexSignature
    let identity: BinaryIdentity
}

/// Por qué un candidato no se ofrece. Se informa, no se oculta.
struct CodexRejection: Equatable, Sendable {
    let path: String
    let reason: String
}

/// Encuentra el ejecutable de Codex y decide cuáles se pueden ofrecer.
///
/// Sin estado: todo son funciones puras sobre el sistema de archivos, inyectables para
/// poder probarlas sin tocar el Codex real de la máquina (ver docs/specs/S2).
enum CodexExecutable {
    /// Rutas absolutas conocidas. El `PATH` se consulta **al final**, porque cualquier
    /// directorio que esté ahí puede aportar el binario que después se ejecuta con el
    /// entorno completo del usuario. Ver docs/specs/S2-verificar-ejecutable-codex.md.
    static let knownPaths = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]

    /// Candidatos aceptables en orden de preferencia, y los descartes con su motivo.
    static func search(override: String? = nil,
                       searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
                       excludedRoots: [URL] = [],
                       known: [String] = knownPaths,
                       fileManager: FileManager = .default)
        -> (candidates: [CodexCandidate], rejected: [CodexRejection]) {
        let fromPath = (searchPath ?? "").split(separator: ":").map { String($0) + "/codex" }
        var seen: Set<String> = []
        var candidates: [CodexCandidate] = []
        var rejected: [CodexRejection] = []
        for path in ([override].compactMap { $0 } + known + fromPath) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seen.insert(resolved).inserted else { continue }
            guard fileManager.isExecutableFile(atPath: resolved) else { continue }
            if let reason = rejection(for: resolved, excludedRoots: excludedRoots) {
                rejected.append(CodexRejection(path: resolved, reason: reason))
                continue
            }
            guard let identity = identity(of: resolved) else {
                rejected.append(CodexRejection(path: resolved, reason: "no se pudo leer el archivo"))
                continue
            }
            let signature = signature(of: resolved)
            guard signature.isOfferable else {
                rejected.append(CodexRejection(path: resolved, reason: signature.label))
                continue
            }
            candidates.append(CodexCandidate(url: URL(fileURLWithPath: resolved),
                                             signature: signature, identity: identity))
        }
        return (candidates, rejected)
    }

    /// Motivo de descarte, o `nil` si el archivo es aceptable.
    static func rejection(for path: String, excludedRoots: [URL]) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "no se pudo consultar el archivo" }
        if info.st_mode & S_IFMT != S_IFREG { return "no es un archivo regular" }
        if info.st_mode & (S_IWGRP | S_IWOTH) != 0 {
            return "lo puede escribir el grupo u otros usuarios"
        }
        if info.st_uid != getuid() && info.st_uid != 0 {
            return "no pertenece al usuario actual ni a root"
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        var parentInfo = stat()
        if stat(parent, &parentInfo) == 0, parentInfo.st_mode & (S_IWGRP | S_IWOTH) != 0 {
            return "su carpeta la puede escribir el grupo u otros usuarios"
        }
        // Un repositorio no puede traer su propio codex y hacer que lo ejecutemos.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for root in excludedRoots {
            let prefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            if resolved.hasPrefix(prefix) { return "está dentro del proyecto abierto" }
        }
        return nil
    }

    static func identity(of path: String) -> BinaryIdentity? {
        var info = stat()
        guard stat(path, &info) == 0, let digest = digest(of: path) else { return nil }
        return BinaryIdentity(path: path, size: Int64(info.st_size), digest: digest)
    }

    /// SHA-256 leyendo por bloques: el binario puede tener decenas de MB y no hay
    /// motivo para tenerlo entero en memoria.
    static func digest(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func signature(of path: String) -> CodexSignature {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return .unsigned }
        let validity = SecStaticCodeCheckValidity(code, [], nil)
        if validity == errSecCSUnsigned { return .unsigned }
        guard validity == errSecSuccess else { return .invalid }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return .adHoc }
        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty {
            return .developerID(team: team)
        }
        let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        return flags & 0x2 != 0 ? .adHoc : .appleSigned
    }
}
