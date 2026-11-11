import Foundation
import MySQLNIO
import NIOCore
import NIOSSL

/// Diagnóstico local y acotado de conexión. No recibe contraseñas ni registra SQL,
/// nombres de servidor, IP, usuarios, bases ni mensajes libres del servidor.
/// No se copia swift-log: sus trazas del protocolo pueden contener autenticación.
actor MySQLDiagnostics {
    static let shared = MySQLDiagnostics(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Braket", isDirectory: true))

    enum Event: String, Sendable {
        case started = "connection.started"
        case resolved = "dns.resolved"
        case connecting = "tcp_tls_auth.started"
        case ready = "connection.authenticated"
        case failed = "connection.failed"
    }

    private let directory: URL
    private let maximumBytes: Int
    private var writeFailure: String?
    private var current: URL { directory.appendingPathComponent("mysql.jsonl") }
    private var previous: URL { directory.appendingPathComponent("mysql.previous.jsonl") }

    init(directory: URL, maximumBytes: Int = 512 * 1024) {
        self.directory = directory
        self.maximumBytes = maximumBytes
    }

    func record(_ event: Event, attempt: UUID, configuration: DatabaseConnection,
                address: SocketAddress? = nil, elapsedMilliseconds: Int? = nil, tlsActive: Bool? = nil, error: Error? = nil) {
        var fields = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "attempt": attempt.uuidString,
            "event": event.rawValue,
            "tls": configuration.tls.rawValue,
            "port": String(configuration.port),
            "hostKind": (try? SocketAddress(ipAddress: configuration.host, port: configuration.port)) == nil ? "dns" : "ip",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "appBuild": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        #if arch(arm64)
        fields["architecture"] = "arm64"
        #else
        fields["architecture"] = "x86_64"
        #endif
        if let address {
            fields["addressFamily"] = address.protocol == .inet6 ? "IPv6" : "IPv4"
            fields["loopback"] = String(address.isLoopbackAddress)
        }
        if let elapsedMilliseconds { fields["elapsedMilliseconds"] = String(elapsedMilliseconds) }
        if let tlsActive { fields["tlsActive"] = String(tlsActive) }
        if let error { fields.merge(Self.errorFields(error)) { _, new in new } }
        do {
            var data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            data.append(0x0A)
            try append(data)
            writeFailure = nil
        } catch {
            writeFailure = error.localizedDescription
            Log.mysql.error("No se pudo guardar el diagnóstico local: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func append(_ data: Data) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let size = (try? files.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 0, size + data.count > maximumBytes {
            if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
            try files.moveItem(at: current, to: previous)
        }
        if !files.fileExists(atPath: current.path) {
            guard files.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func snapshot() throws -> Data {
        if let writeFailure { throw DatabaseFailure("No se pudo guardar el diagnóstico MySQL: \(writeFailure)") }
        var data = Data("Braket · Diagnóstico de conexión MySQL\nFechas en UTC. Sin contraseñas, SQL ni destinos.\n\n".utf8)
        var found = false
        for url in [previous, current] where FileManager.default.fileExists(atPath: url.path) {
            data.append(try Data(contentsOf: url))
            found = true
        }
        if !found { data.append(Data("No hay intentos registrados. Intentá conectar y exportá nuevamente.\n".utf8)) }
        return data
    }

    func export(to url: URL) throws {
        try snapshot().write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Lista permitida: los errores arbitrarios pueden contener SQL, rutas o secretos.
    nonisolated static func errorFields(_ error: Error) -> [String: String] {
        var fields = ["errorType": String(reflecting: type(of: error)), "errorCode": String((error as NSError).code)]
        if let tls = error as? NIOSSLError {
            switch tls {
            case .handshakeFailed(let cause):
                fields["tlsError"] = "handshakeFailed"
                fields["tlsDetail"] = tlsDetail(cause)
            case .shutdownFailed(let cause):
                fields["tlsError"] = "shutdownFailed"
                fields["tlsDetail"] = tlsDetail(cause)
            default:
                fields["tlsError"] = String(describing: tls)
            }
        } else if let tls = error as? NIOSSLExtraError {
            // Su descripción puede incluir el hostname o una ruta después de ':'.
            fields["tlsError"] = String(tls.description.prefix(while: { $0 != ":" }))
        } else if let mysql = error as? MySQLError, case .server(let packet) = mysql {
            fields["mysqlCode"] = String(packet.errorCode.rawValue)
        } else if let io = error as? IOError {
            fields["errno"] = String(io.errnoCode)
        } else if let channel = error as? ChannelError {
            switch channel {
            case .connectTimeout: fields["networkError"] = "connectTimeout"
            case .ioOnClosedChannel: fields["networkError"] = "ioOnClosedChannel"
            default: break
            }
        }
        return fields
    }

    private nonisolated static func tlsDetail(_ error: BoringSSLError) -> String {
        switch error {
        case .sslError(let stack), .unknownError(let stack), .invalidSNIName(let stack), .failedToSetALPN(let stack):
            // Conserva códigos y causas de BoringSSL, quitando rutas del equipo de compilación.
            return stack.prefix(8).map { String(($0.description.components(separatedBy: " at ").first ?? "").prefix(1024)) }
                .joined(separator: " | ")
        default:
            return String(describing: error)
        }
    }
}
