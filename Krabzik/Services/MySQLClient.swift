import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import Logging

struct DatabaseSessionInfo: Sendable {
    var database: String
    var inTransaction: Bool
}

actor MySQLClient {
    private struct Session {
        let connection: MySQLConnection
        let configuration: DatabaseConnection
        let password: String
        let serverID: UInt64
        var database: String
        var flags: MySQLProtocol.StatusFlags = []
    }
    private var group: MultiThreadedEventLoopGroup?
    private var sessions: [UUID: Session] = [:]
    private var busy: Set<UUID> = []
    private var jobs: [UUID: UUID] = [:]
    private var cancelled: Set<UUID> = []
    private var epoch = UUID()

    private func eventLoop() -> any EventLoop {
        if group == nil { group = MultiThreadedEventLoopGroup(numberOfThreads: 1) }
        return group!.next()
    }

    private func open(_ config: DatabaseConnection, password: String) async throws -> MySQLConnection {
        let address = try await Task.detached { try SocketAddress.makeAddressResolvingHost(config.host, port: config.port) }.value
        let loop = eventLoop()
        var logger = Logger(label: "com.krabzik.mysql")
        logger.logLevel = .critical
        let connection = try await MySQLConnection.connect(
            to: address, username: config.username, database: config.database,
            password: password.isEmpty ? nil : password, tlsConfiguration: config.tls == .verified ? .makeClientConfiguration() : nil,
            serverHostname: config.tls == .verified ? config.host : nil, logger: logger, on: loop
        ).get()
        if config.tls == .verified {
            do { _ = try await connection.channel.pipeline.handler(type: NIOSSLClientHandler.self).map { _ in true }.get() }
            catch { try? await connection.close().get(); throw DatabaseFailure("El servidor no ofrece TLS.") }
        }
        return connection
    }

    private func session(_ config: DatabaseConnection, password: String) async throws -> Session {
        if let existing = sessions[config.id], existing.configuration == config, !existing.connection.isClosed { return existing }
        let token = epoch
        let connection = try await open(config, password: password)
        do {
            guard token == epoch else { throw CancellationError() }
            let command = MySQLTextCommand(sql: "SELECT CONNECTION_ID(), DATABASE()", statement: 0, line: 1)
            try await connection.send(command, logger: connection.logger).get()
            let result = try await connection.eventLoop.submit { (command.results, command.status) }.get()
            guard let values = result.0.first?.rows.first, let idText = values.first ?? nil, let serverID = UInt64(idText) else {
                throw DatabaseFailure("No se pudo identificar la sesión MySQL.")
            }
            let value = Session(connection: connection, configuration: config, password: password, serverID: serverID,
                                database: values.count > 1 ? values[1] ?? "" : "", flags: result.1)
            guard token == epoch else { throw CancellationError() }
            sessions[config.id] = value
            return value
        } catch { try? await connection.close().get(); throw error }
    }

    func connect(_ config: DatabaseConnection, password: String) async throws -> DatabaseSessionInfo {
        guard busy.insert(config.id).inserted else { throw DatabaseFailure("La conexión está ocupada.") }
        defer { busy.remove(config.id) }
        let value = try await session(config, password: password)
        return .init(database: value.database, inTransaction: value.flags.contains(.SERVER_STATUS_IN_TRANS))
    }

    func test(_ config: DatabaseConnection, password: String) async throws {
        let connection = try await open(config, password: password)
        do { _ = try await connection.simpleQuery("SELECT 1").get(); try await connection.close().get() }
        catch { try? await connection.close().get(); throw error }
    }

    func execute(_ text: String, startingLine: Int, configuration: DatabaseConnection, password: String,
                 operation: UUID, onResult: @escaping @Sendable (SQLResult) async -> Void) async throws -> DatabaseSessionInfo {
        try Task.checkCancellation()
        let id = configuration.id
        guard busy.insert(id).inserted else { throw DatabaseFailure("La conexión está ocupada.") }
        jobs[operation] = id
        defer { busy.remove(id); jobs.removeValue(forKey: operation); cancelled.remove(operation) }
        var session = try await session(configuration, password: password)
        if cancelled.contains(operation) || Task.isCancelled { await disconnect(id); throw CancellationError() }
        var cursor = SQLScript(text, startingLine: startingLine)
        var statementNumber = 0, remainingBytes = 8_000_000, resultCount = 0
        while let statement = try cursor.next(noBackslashEscapes: session.flags.contains(.SERVER_STATUS_NO_BACKSLASH_ESCAPES)) {
            if cancelled.contains(operation) || Task.isCancelled { throw CancellationError() }
            statementNumber += 1
            guard statementNumber <= 200 else { throw DatabaseFailure("Ejecutá como máximo 200 sentencias por vez.") }
            guard resultCount < 200 else { throw DatabaseFailure("Se alcanzó el límite de 200 resultados por ejecución.") }
            let command = MySQLTextCommand(sql: statement.text, statement: statementNumber, line: statement.line,
                                           byteLimit: min(remainingBytes, 4_000_000), resultLimit: 200 - resultCount)
            do {
                try await session.connection.send(command, logger: session.connection.logger).get()
                let captured = try await session.connection.eventLoop.submit { (command.results, command.status) }.get()
                if cancelled.contains(operation) { throw CancellationError() }
                session.flags = captured.1
                if let database = Self.useDatabase(in: statement.text) { session.database = database }
                sessions[id] = session
                for result in captured.0 {
                    resultCount += 1
                    remainingBytes -= result.rows.reduce(0) { $0 + $1.reduce(0) { $0 + 16 + ($1?.utf8.count ?? 0) } }
                    await onResult(result)
                }
            } catch {
                if cancelled.contains(operation) { throw CancellationError() }
                let captured = try? await session.connection.eventLoop.submit {
                    (command.results, command.status, command.reusableAfterFailure)
                }.get()
                if let captured {
                    for result in captured.0 { await onResult(result) }
                    if !captured.0.isEmpty {
                        session.flags = captured.1
                        sessions[id] = session
                    }
                }
                var failure = SQLResult(statement: statementNumber, line: statement.line)
                failure.error = "Línea \(statement.line): \(Self.message(error))"
                await onResult(failure)
                if captured?.2 != true { await disconnect(id) }
                if session.connection.isClosed { sessions.removeValue(forKey: id) }
                throw DatabaseFailure("La ejecución se detuvo en la sentencia \(statementNumber).")
            }
        }
        guard statementNumber > 0 else { throw DatabaseFailure("No hay sentencias SQL para ejecutar.") }
        if cancelled.contains(operation) || Task.isCancelled { throw CancellationError() }
        return .init(database: session.database, inTransaction: session.flags.contains(.SERVER_STATUS_IN_TRANS))
    }

    func cancel(_ operation: UUID) async {
        guard let id = jobs[operation] else { return }
        cancelled.insert(operation)
        guard let value = sessions.removeValue(forKey: id) else { return }
        // Closing a TCP socket alone does not reliably interrupt a long server query.
        // A second, short-lived connection terminates only this app-owned session.
        do {
            let control = try await open(value.configuration, password: value.password)
            do { _ = try await control.simpleQuery("KILL CONNECTION \(value.serverID)").get() } catch { }
            try? await control.close().get()
        } catch { }
        try? await value.connection.close().get()
    }

    func disconnect(_ id: UUID) async {
        if let session = sessions.removeValue(forKey: id) { try? await session.connection.close().get() }
    }

    func info(_ id: UUID) -> DatabaseSessionInfo? {
        guard let session = sessions[id], !session.connection.isClosed else { return nil }
        return .init(database: session.database, inTransaction: session.flags.contains(.SERVER_STATUS_IN_TRANS))
    }

    func closeAll() async {
        epoch = UUID()
        for operation in Array(jobs.keys) { await cancel(operation) }
        for id in Array(sessions.keys) { await disconnect(id) }
    }

    func shutdown() async {
        await closeAll()
        if let group {
            self.group = nil
            try? await group.shutdownGracefully()
        }
    }

    nonisolated static func message(_ error: Error) -> String {
        if let error = error as? DatabaseFailure { return error.message }
        if error is CancellationError { return "Ejecución cancelada. La conexión se cerró." }
        if let error = error as? MySQLError { return error.description }
        return error.localizedDescription
    }

    nonisolated private static func useDatabase(in sql: String) -> String? {
        let pattern = #"(?is)^\s*(?:/\*.*?\*/\s*|--[^\n]*\n\s*|#[^\n]*\n\s*)*USE\s+(?:`((?:``|[^`])+)`|([\p{L}\p{N}_$]+))\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sql, range: NSRange(location: 0, length: (sql as NSString).length)) else { return nil }
        let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
        return (sql as NSString).substring(with: range).replacingOccurrences(of: "``", with: "`")
    }
}
