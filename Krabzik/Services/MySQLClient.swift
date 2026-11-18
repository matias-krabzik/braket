import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

extension SocketAddress {
    /// `true` solo para 127.0.0.0/8 y ::1, incluida la forma IPv4 mapeada.
    /// Un socket Unix no aplica y devuelve `false`.
    var isLoopbackAddress: Bool {
        guard let ip = ipAddress?.lowercased() else { return false }
        if ip == "::1" || ip == "0:0:0:0:0:0:0:1" { return true }
        let v4 = ip.hasPrefix("::ffff:") ? String(ip.dropFirst(7)) : ip
        guard v4.hasPrefix("127.") else { return false }
        let parts = v4.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}

/// Lo que la interfaz necesita saber de una sesión viva: base actual y si hay una
/// transacción abierta.
struct DatabaseSessionInfo: Sendable {
    var database: String
    var inTransaction: Bool
    var noBackslashEscapes = false
}

/// El cliente de MySQL: una sesión persistente por conexión.
///
/// Es un `actor` porque el estado —sesiones, trabajos en curso, cancelaciones— se toca
/// desde la interfaz y desde las tareas de ejecución. La sesión es persistente a
/// propósito: conserva tablas temporales, variables y transacciones entre ejecuciones,
/// que es lo que hace útil un script SQL por partes.
///
/// No guarda la contraseña: la relee del llavero cuando hace falta (S4).
actor MySQLClient {
    /// Resultado de cancelar. `localOnly` significa que se cerró el socket pero el
    /// servidor pudo no haber recibido el KILL: la consulta puede seguir corriendo.
    enum CancelOutcome: Sendable, Equatable {
        case killed
        case localOnly(reason: String)
    }

    /// Cómo se obtiene la contraseña cuando hace falta reconectar para cancelar.
    /// Inyectable para poder probar el camino de fallo sin tocar el llavero real.
    private let readPassword: @Sendable (DatabaseConnection) throws -> String
    private let diagnostics: MySQLDiagnostics
    private let historyProvider: @MainActor @Sendable () -> SQLHistoryStore?
    private var jobHistory: [UUID: SQLHistoryStore] = [:]

    init(diagnostics: MySQLDiagnostics = .shared,
         readPassword: @escaping @Sendable (DatabaseConnection) throws -> String = { try CredentialStore.read(for: $0) },
         historyProvider: @escaping @MainActor @Sendable () -> SQLHistoryStore? = { nil }) {
        self.historyProvider = historyProvider
        self.readPassword = readPassword
        self.diagnostics = diagnostics
    }

    /// Una conexión viva con lo que hay que recordar de ella. `serverID` es el id de
    /// sesión del servidor, lo único con lo que se puede matar esta consulta y no otra.
    private struct Session {
        let connection: MySQLConnection
        let configuration: DatabaseConnection
        let serverID: UInt64
        var database: String
        var flags: MySQLProtocol.StatusFlags = []
    }
    private var group: MultiThreadedEventLoopGroup?
    private var sessions: [UUID: Session] = [:]
    private var busy: Set<UUID> = []
    private var jobs: [UUID: UUID] = [:]
    private var cancelled: Set<UUID> = []
    private var timedOut: Set<UUID> = []
    private var epoch = UUID()

    /// El grupo de eventos se crea la primera vez que se usa y vive hasta `shutdown()`:
    /// un hilo para todas las conexiones del IDE.
    private func eventLoop() -> any EventLoop {
        if let group { return group.next() }
        let created = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        group = created
        return created.next()
    }

    private func open(_ config: DatabaseConnection, password: String) async throws -> MySQLConnection {
        let attempt = UUID(), started = ContinuousClock.now
        await diagnostics.record(.started, attempt: attempt, configuration: config)
        do {
            let connection = try await establish(config.validated(), password: password, attempt: attempt)
            let tlsActive = (try? await connection.channel.pipeline.handler(type: NIOSSLClientHandler.self).get()) != nil
            await diagnostics.record(.ready, attempt: attempt, configuration: config,
                                     elapsedMilliseconds: Self.milliseconds(since: started), tlsActive: tlsActive)
            return connection
        } catch {
            await diagnostics.record(.failed, attempt: attempt, configuration: config,
                                     elapsedMilliseconds: Self.milliseconds(since: started), error: error)
            throw error
        }
    }

    private nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    private func establish(_ config: DatabaseConnection, password: String, attempt: UUID) async throws -> MySQLConnection {
        let address = try await Task.detached { try SocketAddress.makeAddressResolvingHost(config.host, port: config.port) }.value
        await diagnostics.record(.resolved, attempt: attempt, configuration: config, address: address)
        let loop = eventLoop()
        let level = MySQLLogHandler.configuredLevel()
        var logger = Logger(label: "com.krabzik.mysql") { _ in MySQLLogHandler(logLevel: level) }
        logger.logLevel = level
        await diagnostics.record(.connecting, attempt: attempt, configuration: config)
        var tls: TLSConfiguration?
        if config.tls != .disabled {
            var configuration = TLSConfiguration.makeClientConfiguration()
            switch config.tls {
            case .preferred, .required: configuration.certificateVerification = .none
            case .verifyCA: configuration.certificateVerification = .noHostnameVerification
            case .verified: break
            case .disabled: break
            }
            if let path = config.tlsCAPath, config.tls == .verifyCA || config.tls == .verified {
                configuration.trustRoots = .file(path)
            }
            if let certificate = config.tlsClientCertificatePath, let key = config.tlsClientKeyPath {
                configuration.certificateChain = try NIOSSLCertificate.fromPEMFile(certificate).map { .certificate($0) }
                configuration.privateKey = .privateKey(try NIOSSLPrivateKey(file: key, format: .pem))
            }
            tls = configuration
        }
        let connection = try await MySQLConnection.connect(to: address, username: config.username, database: config.database,
                                                           password: password.isEmpty ? nil : password,
                                                           tlsConfiguration: tls, tlsRequired: config.tls.requiresTLS,
                                                           serverHostname: config
                                                           .tlsServerName ?? (config.tls == .verified ? config.host : nil),
                                                           logger: logger,
                                                           connectTimeout: .seconds(Int64(config.effectiveConnectTimeout)),
                                                           on: loop).get()
        if config.tls.requiresTLS {
            do { _ = try await connection.channel.pipeline.handler(type: NIOSSLClientHandler.self).map { _ in true }.get() }
            catch {
                try? await connection.close().get()
                throw DatabaseFailure("El servidor no ofrece TLS.")
            }
        }
        // El host y el usuario van como privados; el modo de TLS es lo que importa poder
        // leer sin autorización especial.
        let mode = config.tls.rawValue
        let endpoint = "\(config.username)@\(config.host):\(config.port)"
        Log.mysql.info("conexión establecida · TLS \(mode, privacy: .public) · \(endpoint, privacy: .private)")
        return connection
    }

    private func session(_ config: DatabaseConnection, password: String, history: SQLHistoryStore?) async throws -> Session {
        if let existing = sessions[config.id], existing.configuration.configurationWithoutTint == config.configurationWithoutTint,
           !existing.connection.isClosed { return existing }
        let token = epoch
        let connection = try await open(config, password: password)
        do {
            guard token == epoch else { throw CancellationError() }
            let command = MySQLTextCommand(sql: "SELECT CONNECTION_ID(), DATABASE()", statement: 0, line: 1)
            try await sendLogged(command, on: connection, configuration: config, database: config.database,
                                 history: history, source: "Sesión")
            let result = try await connection.eventLoop.submit { (command.results, command.status) }.get()
            guard let values = result.0.first?.rows.first, let idText = values.first ?? nil, let serverID = UInt64(idText) else {
                throw DatabaseFailure("No se pudo identificar la sesión MySQL.")
            }
            let value = Session(connection: connection, configuration: config, serverID: serverID,
                                database: values.count > 1 ? values[1] ?? "" : "", flags: result.1)
            guard token == epoch else { throw CancellationError() }
            sessions[config.id] = value
            return value
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    func connect(_ config: DatabaseConnection, password: String) async throws -> DatabaseSessionInfo {
        guard busy.insert(config.id).inserted else { throw DatabaseFailure("La conexión está ocupada.") }
        defer { busy.remove(config.id) }
        let value = try await session(config, password: password, history: await historyProvider())
        return .init(database: value.database, inTransaction: value.flags.contains(.SERVER_STATUS_IN_TRANS),
                     noBackslashEscapes: value.flags.contains(.SERVER_STATUS_NO_BACKSLASH_ESCAPES))
    }

    func test(_ config: DatabaseConnection, password: String) async throws {
        let history = await historyProvider()
        let connection = try await open(config, password: password)
        do {
            let command = MySQLTextCommand(sql: "SELECT 1", statement: 0, line: 1)
            try await sendLogged(command, on: connection, configuration: config, database: config.database,
                                 history: history, source: "Prueba de conexión")
            try await connection.close().get()
        }
        catch {
            try? await connection.close().get()
            throw error
        }
    }

    func execute(_ text: String, startingLine: Int, configuration: DatabaseConnection, password: String,
                 operation: UUID, timeoutSeconds: Int = 15, pageIndex: Int? = nil,
                 onStatement: @escaping @Sendable (SQLResult) async throws -> Void = { _ in },
                 onResult: @escaping @Sendable (SQLResult) async -> Void) async throws -> DatabaseSessionInfo {
        try Task.checkCancellation()
        let id = configuration.id
        guard busy.insert(id).inserted else { throw DatabaseFailure("La conexión está ocupada.") }
        let history = await historyProvider()
        jobs[operation] = id
        jobHistory[operation] = history
        defer {
            busy.remove(id)
            jobs.removeValue(forKey: operation)
            jobHistory.removeValue(forKey: operation)
            cancelled.remove(operation)
            timedOut.remove(operation)
        }
        var session = try await session(configuration, password: password, history: history)
        if cancelled.contains(operation) || Task.isCancelled {
            await disconnect(id)
            throw CancellationError()
        }
        var cursor = SQLScript(text, startingLine: startingLine)
        var statementNumber = 0, remainingBytes = 8_000_000, resultCount = 0
        while let statement = try cursor.next(noBackslashEscapes: session.flags.contains(.SERVER_STATUS_NO_BACKSLASH_ESCAPES)) {
            if cancelled.contains(operation) || Task.isCancelled { throw CancellationError() }
            statementNumber += 1
            guard statementNumber <= 200 else { throw DatabaseFailure("Ejecutá como máximo 200 sentencias por vez.") }
            guard resultCount < 200 else { throw DatabaseFailure("Se alcanzó el límite de 200 resultados por ejecución.") }
            var pending = SQLResult(statement: statementNumber, line: statement.line)
            pending.sql = statement.text
            pending.connection = configuration
            pending.database = session.database
            let setStatement = SQLSetStatement(statement.text,
                                               noBackslashEscapes: session.flags.contains(.SERVER_STATUS_NO_BACKSLASH_ESCAPES))
            pending.setValues = setStatement == nil ? nil : []
            let pagination = pageIndex.flatMap {
                SQLPagination(statement.text, page: $0, noBackslashEscapes: session.flags.contains(.SERVER_STATUS_NO_BACKSLASH_ESCAPES))
            }
            if let pagination { pending.page = SQLPage(index: pagination.index) }
            try await onStatement(pending)
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(max(1, min(timeoutSeconds, 3600)))) }
                catch { return }
                await self.expire(operation)
            }
            let command = MySQLTextCommand(sql: pagination?.query ?? statement.text, statement: statementNumber, line: statement.line,
                                           byteLimit: min(remainingBytes, 4_000_000), resultLimit: 200 - resultCount)
            do {
                try await sendLogged(command, on: session.connection, configuration: configuration, database: pending.database,
                                     history: history, source: "Consulta", operation: operation)
                let captured = try await session.connection.eventLoop.submit { (command.results, command.status) }.get()
                if timedOut.contains(operation) { throw DatabaseFailure("La consulta superó el límite de \(timeoutSeconds) segundos.") }
                if cancelled.contains(operation) { throw CancellationError() }
                session.flags = captured.1
                if let database = Self.useDatabase(in: statement.text) { session.database = database }
                sessions[id] = session
                var totalRows: Int?
                if let pagination, let countSQL = pagination.countQuery,
                   captured.0.count == 1, captured.0[0].rowCount > SQLPage.size || pagination.index > 0 {
                    let count = MySQLTextCommand(sql: countSQL, statement: 0, line: 1)
                    do {
                        try await sendLogged(count, on: session.connection, configuration: configuration, database: pending.database,
                                             history: history, source: "Paginación", operation: operation)
                        let value = try await session.connection.eventLoop.submit { count.results.first?.rows.first?.first }.get()
                        totalRows = value.flatMap { $0 }.flatMap(Int.init)
                    } catch {
                        if timedOut.contains(operation) || cancelled.contains(operation) { throw error }
                        // Algunos SELECT (por ejemplo, columnas duplicadas) no admiten una tabla derivada.
                        let reusable = try await session.connection.eventLoop.submit { count.reusableAfterFailure }.get()
                        if !reusable { throw error }
                    }
                }
                var setValues: [SQLSetValue]?
                if let setStatement {
                    setValues = setStatement.targets.isEmpty ? [SQLSetValue(name: "SET", value: "Aplicado")]
                        : setStatement.targets.map { SQLSetValue(name: $0.label, value: "No disponible") }
                    if let query = setStatement.query {
                        do {
                            let values = try await read(query, on: session.connection, configuration: configuration,
                                                        history: nil, source: "Variables SET")
                            if let row = values.rows.first, row.count == setStatement.targets.count {
                                setValues = zip(setStatement.targets, row).map { target, value in
                                    SQLSetValue(name: target.label, value: value.map { $0.count >= 2048 ? $0 + "…" : $0 } ?? "NULL")
                                }
                            }
                        } catch {
                            if timedOut.contains(operation) || cancelled.contains(operation) { throw error }
                            setValues = setStatement.targets.map { SQLSetValue(name: $0.label, value: "No disponible") }
                        }
                    }
                }
                timeout.cancel()
                if timedOut.contains(operation) { throw DatabaseFailure("La consulta superó el límite de \(timeoutSeconds) segundos.") }
                for (index, result) in captured.0.enumerated() {
                    resultCount += 1
                    remainingBytes -= result.rows.reduce(0) { $0 + $1.reduce(0) { $0 + 16 + ($1?.utf8.count ?? 0) } }
                    var contextual = result
                    contextual.resultIndex = index
                    contextual.sql = statement.text
                    contextual.setValues = setValues
                    if let pagination {
                        let hasNext = result.rowCount > SQLPage.size
                        let knownTotal = totalRows ?? (!hasNext ? pagination.index * SQLPage.size + result.rowCount : nil)
                        contextual.page = SQLPage(index: pagination.index, totalRows: knownTotal, hasNext: hasNext)
                        contextual.rows = Array(result.rows.prefix(SQLPage.size))
                        contextual.rowCount = contextual.rows.count
                    }
                    contextual.connection = configuration
                    contextual.database = pending.database
                    await onResult(contextual)
                }
            } catch {
                timeout.cancel()
                if timedOut.contains(operation) {
                    throw DatabaseFailure("La consulta superó el límite de \(timeoutSeconds) segundos. Ajustá el timeout y reintentá.")
                }
                if cancelled.contains(operation) { throw CancellationError() }
                let captured = try? await session.connection.eventLoop.submit {
                    (command.results, command.status, command.reusableAfterFailure)
                }.get()
                if let captured {
                    for (index, result) in captured.0.enumerated() { var contextual = result
                    contextual.resultIndex = index
                    contextual.sql = statement.text
                    contextual.setValues = pending.setValues
                    contextual.connection = configuration
                    contextual.database = pending.database
                    await onResult(contextual) }
                    if !captured.0.isEmpty {
                        session.flags = captured.1
                        sessions[id] = session
                    }
                }
                var failure = pending
                failure.resultIndex = captured?.0.count ?? 0
                failure.error = "Línea \(statement.line): \(Self.message(error))"
                await onResult(failure)
                if captured?.2 != true { await disconnect(id) }
                if session.connection.isClosed { sessions.removeValue(forKey: id) }
                throw DatabaseFailure("La ejecución se detuvo en la sentencia \(statementNumber).")
            }
        }
        guard statementNumber > 0 else { throw DatabaseFailure("No hay sentencias SQL para ejecutar.") }
        if cancelled.contains(operation) || Task.isCancelled { throw CancellationError() }
        return .init(database: session.database, inTransaction: session.flags.contains(.SERVER_STATUS_IN_TRANS),
                     noBackslashEscapes: session.flags.contains(.SERVER_STATUS_NO_BACKSLASH_ESCAPES))
    }

    private func sendLogged(_ command: MySQLTextCommand, on connection: MySQLConnection,
                            configuration: DatabaseConnection, database: String, history: SQLHistoryStore?,
                            source: String, operation: UUID? = nil, deadline: NIODeadline? = nil) async throws {
        let token = await history?.begin(sql: command.sql, configuration: configuration, database: database, source: source)
        let started = ContinuousClock.now
        do {
            try await connection.send(command, logger: connection.logger).get()
            let totals = try await connection.eventLoop.submit {
                (command.results.reduce(0) { $0 + $1.rowCount }, command.results.reduce(UInt64(0)) { $0 &+ $1.affectedRows })
            }.get()
            if let token {
                await history?.finish(token, status: "success", elapsed: Double(Self.milliseconds(since: started)) / 1000,
                                      rows: totals.0, affected: totals.1)
            }
        } catch {
            let timeout = operation.map { timedOut.contains($0) } == true || deadline.map { NIODeadline.now() >= $0 } == true
            let cancelled = Task.isCancelled || operation.map { self.cancelled.contains($0) } == true
            if let token {
                await history?.finish(token, status: timeout ? "timeout" : cancelled ? "cancelled" : "error",
                                      elapsed: Double(Self.milliseconds(since: started)) / 1000,
                                      error: timeout ? "La consulta superó el tiempo límite." : Self.message(error))
            }
            throw error
        }
    }

    private func read(_ sql: String, on connection: MySQLConnection, configuration: DatabaseConnection,
                      history: SQLHistoryStore?, source: String = "Grilla", deadline: NIODeadline? = nil) async throws -> SQLResult {
        let command = MySQLTextCommand(sql: sql, statement: 0, line: 1)
        try await sendLogged(command, on: connection, configuration: configuration,
                             database: sessions[configuration.id]?.database ?? configuration.database,
                             history: history, source: source, deadline: deadline)
        let results = try await connection.eventLoop.submit { command.results }.get()
        guard let result = results.first, !result.truncated else {
            throw DatabaseFailure("La estructura supera el límite de lectura; seleccioná menos bases.")
        }
        return result
    }

    /// A metadata timeout closes only its private socket, never the editor's SQL session.
    private func readMetadata(_ sql: String, on connection: MySQLConnection, configuration: DatabaseConnection,
                              history: SQLHistoryStore?,
                              timeoutMilliseconds: Int64 = 15_000) async throws -> SQLResult {
        try Task.checkCancellation()
        let deadline = NIODeadline.now() + .milliseconds(timeoutMilliseconds)
        let channel = connection.channel
        let timeout = connection.eventLoop.scheduleTask(deadline: deadline) { channel.close(promise: nil) }
        defer { timeout.cancel() }
        do {
            return try await withTaskCancellationHandler {
                let result = try await read(sql, on: connection, configuration: configuration,
                                            history: history, source: "Explorador", deadline: deadline)
                try Task.checkCancellation()
                return result
            } onCancel: { channel.close(promise: nil) }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if NIODeadline.now() >= deadline {
                throw DatabaseFailure("El servidor no respondió a la consulta de estructura a tiempo. "
                                      + "Podés reintentar o elegir menos bases.")
            }
            throw error
        }
    }

    func metadataQuery(_ sql: String, configuration: DatabaseConnection, password: String,
                       timeoutMilliseconds: Int64 = 15_000) async throws -> SQLResult {
        let history = await historyProvider()
        let connection = try await open(configuration, password: password)
        do {
            let result = try await readMetadata(sql, on: connection, configuration: configuration, history: history,
                                                timeoutMilliseconds: timeoutMilliseconds)
            try? await connection.close().get()
            return result
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    func databases(_ config: DatabaseConnection, password: String) async throws -> [String] {
        let result = try await metadataQuery("SHOW DATABASES", configuration: config, password: password)
        return result.rows.compactMap { $0.first ?? nil }
    }

    func schema(_ config: DatabaseConnection, password: String, databases: [String],
                progress: @escaping @Sendable (SQLSchemaProgress) async -> Void = { _ in }) async throws -> SQLSchemaSnapshot {
        let history = await historyProvider()
        let connection = try await open(config, password: password)
        do {
            let loader = SQLSchemaLoader { sql in
                try await self.readMetadata(sql, on: connection, configuration: config, history: history)
            }
            let snapshot = try await loader.load(connection: config, databases: databases, progress: progress)
            try? await connection.close().get()
            return snapshot
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    private func describe(_ table: SQLSchemaTable, on connection: MySQLConnection, configuration: DatabaseConnection,
                          history: SQLHistoryStore?) async throws -> SQLSchemaTable {
        var table = table
        let predicate = " WHERE TABLE_SCHEMA = " + SQLValue.literal(table.database) + " AND TABLE_NAME = " + SQLValue.literal(table.name)
        let columns = try await read("SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA "
                                     + "FROM INFORMATION_SCHEMA.COLUMNS" + predicate + " ORDER BY ORDINAL_POSITION", on: connection,
                                     configuration: configuration, history: history)
        table.columns = columns.rows.compactMap { row in
            guard row.count == 5, let name = row[0], let type = row[1] else { return nil }
            return SQLSchemaColumn(name: name, type: type, nullable: row[2] == "YES", defaultValue: row[3], extra: row[4] ?? "")
        }
        let keys = try await read("SELECT INDEX_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.STATISTICS" + predicate
                                  + " AND NON_UNIQUE = 0 ORDER BY INDEX_NAME, SEQ_IN_INDEX", on: connection, configuration: configuration,
                                  history: history)
        var grouped: [String: [String]] = [:]
        var invalid: Set<String> = []
        for row in keys.rows where row.count == 2 {
            guard let name = row[0] else { continue }
            if let column = row[1] { grouped[name, default: []].append(column) }
            else { invalid.insert(name) }
        }
        table.primaryKey = invalid.contains("PRIMARY") ? [] : (grouped["PRIMARY"] ?? [])
        table.uniqueKeys = grouped.keys.sorted().filter { !invalid.contains($0) }.compactMap { grouped[$0] }
        return table
    }

    /// Usa la sesión del resultado: una conexión de metadatos perdería su time_zone y timestamp.
    func serverNow(column: SQLSchemaColumn, configuration: DatabaseConnection) async throws -> String {
        guard case .temporal(let kind, let precision) = column.cellKind else {
            throw DatabaseFailure("Este campo no es una fecha ni una hora.")
        }
        guard busy.insert(configuration.id).inserted else { throw DatabaseFailure("La conexión está ocupada.") }
        defer { busy.remove(configuration.id) }
        let history = await historyProvider()
        guard let session = sessions[configuration.id], !session.connection.isClosed,
              session.configuration.configurationWithoutTint == configuration.configurationWithoutTint else {
            throw DatabaseFailure("La sesión MySQL está desconectada. Volvé a conectarla para consultar su hora.")
        }
        let channel = session.connection.channel
        let deadline = NIODeadline.now() + .seconds(15)
        let timeout = channel.eventLoop.scheduleTask(deadline: deadline) { channel.close(promise: nil) }
        defer { timeout.cancel() }
        do {
            let result = try await read(kind.currentQuery(precision: precision), on: session.connection,
                                        configuration: configuration, history: history, source: "Grilla · Ahora", deadline: deadline)
            guard result.rows.count == 1, let row = result.rows.first, row.count == 1, let value = row[0] else {
                throw DatabaseFailure("MySQL no devolvió una fecha u hora válida.")
            }
            try Task.checkCancellation()
            return try SQLCellInput.validate(value, column: column)
        } catch {
            if NIODeadline.now() >= deadline { throw DatabaseFailure("El servidor no respondió a tiempo al consultar su hora.") }
            throw error
        }
    }

    func createTable(_ table: SQLSchemaTable, config: DatabaseConnection, password: String) async throws -> String {
        let result = try await metadataQuery("SHOW CREATE TABLE " + table.qualified, configuration: config, password: password)
        return result.rows.first.flatMap { $0.count > 1 ? $0[1] : nil } ?? ""
    }

    func useDatabase(_ database: String, config: DatabaseConnection, password: String) async throws -> DatabaseSessionInfo {
        try await execute("USE " + SQLValue.identifier(database), startingLine: 1, configuration: config,
                          password: password, operation: UUID()) { _ in }
    }

    func apply(_ mutations: [SQLMutation], table: SQLSchemaTable, configuration: DatabaseConnection,
               password: String) async throws {
        guard !mutations.isEmpty, busy.insert(configuration.id).inserted else { throw DatabaseFailure("La conexión está ocupada.") }
        defer { busy.remove(configuration.id) }
        let history = await historyProvider()
        let session = try await session(configuration, password: password, history: history)
        guard !session.flags.contains(.SERVER_STATUS_IN_TRANS), session.flags.contains(.SERVER_STATUS_AUTOCOMMIT) else {
            throw DatabaseFailure("Finalizá la transacción del script y activá autocommit antes de enviar cambios de la grilla.")
        }
        let fresh = try await describe(table, on: session.connection, configuration: configuration, history: history)
        guard fresh.columns == table.columns, fresh.uniqueKeys == table.uniqueKeys,
              table.primaryKey == nil || fresh.primaryKey == table.primaryKey else {
            throw DatabaseFailure("La estructura cambió. Actualizá la consulta antes de editar.")
        }
        let engine = try await read("SELECT ENGINE FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = "
                                    + SQLValue.literal(table.database) + " AND TABLE_NAME = " + SQLValue.literal(table.name),
                                    on: session.connection, configuration: configuration, history: history)
        guard (engine.rows.first?.first ?? nil)?.uppercased() == "INNODB" else {
            throw DatabaseFailure("La edición requiere una tabla InnoDB.")
        }
        _ = try await read("START TRANSACTION", on: session.connection, configuration: configuration, history: history)
        do {
            for mutation in mutations {
                if let verification = mutation.verificationSQL {
                    let matching = try await read(verification, on: session.connection, configuration: configuration, history: history)
                    guard mutation.matchesOriginal(matching.rows) else {
                        throw DatabaseFailure("La fila cambió o ya no existe. Se revirtieron los cambios.")
                    }
                }
                let result = try await read(mutation.sql, on: session.connection, configuration: configuration, history: history)
                guard (result.affectedRows == 1 || (mutation.allowsUnchanged && result.affectedRows == 0)), result.warnings == 0 else {
                    throw DatabaseFailure("La fila cambió, ya no existe o el servidor rechazó un valor. Se revirtieron los cambios.")
                }
            }
        } catch {
            do { _ = try await read("ROLLBACK", on: session.connection, configuration: configuration, history: history) }
            catch { await disconnect(configuration.id) }
            throw error
        }
        do { _ = try await read("COMMIT", on: session.connection, configuration: configuration, history: history) }
        catch {
            await disconnect(configuration.id)
            throw DatabaseFailure("No se pudo confirmar la respuesta de COMMIT. Consultá los datos antes de volver a enviar.")
        }
    }

    private func expire(_ operation: UUID) async {
        guard jobs[operation] != nil, !Task.isCancelled else { return }
        timedOut.insert(operation)
        await cancel(operation)
    }

    @discardableResult
    func cancel(_ operation: UUID) async -> CancelOutcome {
        guard let id = jobs[operation] else { return .killed }
        cancelled.insert(operation)
        guard let value = sessions.removeValue(forKey: id) else { return .killed }
        // Liberar inmediatamente la espera local, incluso si el canal de control tarda.
        value.connection.channel.close(promise: nil)
        // Cerrar el socket no interrumpe de forma fiable una consulta larga en el
        // servidor. Una segunda conexión corta termina solo esta sesión, que es de
        // la app. La contraseña se relee del llavero: la sesión no la guarda.
        let history = jobHistory[operation]
        var outcome = CancelOutcome.killed
        do {
            let configuration = value.configuration
            let reader = readPassword
            let password = try await Task.detached(priority: .userInitiated) {
                try reader(configuration)
            }.value
            let control = try await open(configuration, password: password)
            do {
                let command = MySQLTextCommand(sql: "KILL CONNECTION \(value.serverID)", statement: 0, line: 1)
                try await sendLogged(command, on: control, configuration: configuration, database: value.database,
                                     history: history, source: "Cancelación")
            } catch {
                Log.mysql.error("KILL CONNECTION falló: \(Self.message(error), privacy: .private)")
                outcome = .localOnly(reason: Self.message(error))
            }
            try? await control.close().get()
        } catch {
            Log.mysql.error("sin conexión de control para cancelar: \(Self.message(error), privacy: .private)")
            outcome = .localOnly(reason: Self.message(error))
        }
        try? await value.connection.close().get()
        return outcome
    }

    func disconnect(_ id: UUID) async {
        if let session = sessions.removeValue(forKey: id) { try? await session.connection.close().get() }
    }

    func info(_ id: UUID) -> DatabaseSessionInfo? {
        guard let session = sessions[id], !session.connection.isClosed else { return nil }
        return .init(database: session.database, inTransaction: session.flags.contains(.SERVER_STATUS_IN_TRANS),
                     noBackslashEscapes: session.flags.contains(.SERVER_STATUS_NO_BACKSLASH_ESCAPES))
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

    /// Se conserva como nombre porque lo usan las vistas de base de datos, pero la regla
    /// está en un solo lugar: `AppError.describe(_:)`.
    nonisolated static func message(_ error: Error) -> String { AppError.describe(error) }

    nonisolated private static func useDatabase(in sql: String) -> String? {
        let pattern = #"(?is)^\s*(?:/\*.*?\*/\s*|--[^\n]*\n\s*|#[^\n]*\n\s*)*USE\s+(?:`((?:``|[^`])+)`|([\p{L}\p{N}_$]+))\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sql, range: NSRange(location: 0, length: (sql as NSString).length)) else { return nil }
        let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
        return (sql as NSString).substring(with: range).replacingOccurrences(of: "``", with: "`")
    }
}
