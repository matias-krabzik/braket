import Foundation
import Observation

struct DatabaseConnection: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = "MySQL local"
    var host = "127.0.0.1"
    var port = 3306
    var username = "root"
    var database = ""
    var tls: TLSMode = .verified

    enum TLSMode: String, Codable, CaseIterable, Sendable {
        case verified, disabled
        var label: String { self == .verified ? "Verificar certificado" : "Sin TLS" }
    }

    var destination: String { "\(host):\(port)" + (database.isEmpty ? "" : " / \(database)") }

    /// Nivel de exigencia. `validated()` se usa en dos contextos distintos y no
    /// pueden compartir reglas: al GUARDAR desde la hoja hay que rechazar lo
    /// inválido, pero al LEER un `.krabzik` existente rechazar significaría que
    /// el proyecto deja de abrirse. Ver docs/specs/S3-tls-solo-loopback.md.
    enum ValidationLevel {
        /// Guardar y conectar: aplica todas las reglas.
        case strict
        /// Leer un proyecto: solo lo que haría imposible usar la conexión.
        case lenient
    }

    /// `true` solo para extremos locales: 127.0.0.0/8, ::1, `localhost` y
    /// subdominios `.localhost`. `localhost.ejemplo.com` es `false`.
    var isLoopbackHost: Bool {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "localhost" || value.hasSuffix(".localhost") { return true }
        if value == "::1" || value == "[::1]" { return true }
        guard value.hasPrefix("127.") else { return false }
        // Que empiece con "127." no alcanza: "127.malicioso.example" no es una IP.
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    func validated(_ level: ValidationLevel = .strict) throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        value.database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, !value.host.isEmpty, !value.username.isEmpty, (1...65535).contains(port) else {
            throw DatabaseFailure("Completá nombre, servidor, usuario y un puerto válido.")
        }
        guard ![value.host, value.username, value.database].contains(where: { $0.contains("\0") || $0.contains("\n") }) else {
            throw DatabaseFailure("La conexión contiene caracteres no válidos.")
        }
        if level == .strict, value.tls == .disabled, !value.isLoopbackHost {
            throw DatabaseFailure("Sin TLS solo se permite para conexiones locales (127.0.0.1, ::1 o localhost).")
        }
        return value
    }
}

struct DatabaseFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SQLResult: Identifiable, Sendable {
    let id = UUID()
    var statement: Int
    var line: Int
    var columns: [String] = []
    var rows: [[String?]] = []
    var rowCount = 0
    var affectedRows: UInt64 = 0
    var warnings = 0
    var truncated = false
    var elapsed: TimeInterval = 0
    var error: String?

    var summary: String {
        if let error { return error }
        let count = columns.isEmpty ? "\(affectedRows) filas afectadas" : "\(rowCount) filas"
        let limit = truncated ? " · vista limitada a \(rows.count) filas" : ""
        let warning = warnings == 0 ? "" : " · \(warnings) avisos"
        return count + limit + warning + " · \(Int(elapsed * 1000)) ms"
    }
}

@MainActor @Observable
final class SQLExecution {
    var results: [SQLResult] = []
    var selectedResultID: UUID?
    var isRunning = false
    var isCancelling = false
    var connectionName = ""
    var destination = ""
    var error: String?
    /// Aviso adicional cuando la cancelación no llegó al servidor. Va aparte de
    /// `error` porque el propio `execute` escribe ahí al terminar cancelado.
    var cancelNote: String?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var operationID: UUID?

    var selectedResult: SQLResult? { results.first { $0.id == selectedResultID } ?? results.last }
}

@MainActor @Observable
final class DatabaseState {
    enum Status { case disconnected, connecting, connected }
    var status: Status = .disconnected
    var error: String?
    var currentDatabase = ""
    var inTransaction = false
    var busy = false
}
