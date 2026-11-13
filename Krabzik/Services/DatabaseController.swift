import AppKit
import Observation

/// La contraseña se lee del llavero justo antes de usarla y viaja como parámetro.
/// NO se guarda en el estado observable ni en `SQLExecution`, aunque sería cómodo
/// para no releerla: acotar su vida es el punto de docs/specs/S4-no-retener-password.md.
@MainActor @Observable
final class DatabaseController {
    var showingConnections = false
    var editingConnection: DatabaseConnection?
    var states: [UUID: DatabaseState] = [:]
    var resultsVisible = true
    var browserShowsDatabases = false
    let schema = SQLSchemaStore()
    @ObservationIgnored let client = MySQLClient()
    @ObservationIgnored private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    func state(_ id: UUID) -> DatabaseState {
        if let state = states[id] { return state }
        let state = DatabaseState()
        states[id] = state
        return state
    }

    func connect(_ connection: DatabaseConnection) {
        let state = state(connection.id)
        guard state.status == .disconnected, !state.busy else { return }
        state.status = .connecting
        state.error = nil
        connectionTasks[connection.id] = Task {
            defer { connectionTasks.removeValue(forKey: connection.id) }
            do {
                let password = try CredentialStore.read(for: connection)
                let info = try await client.connect(connection, password: password)
                state.currentDatabase = info.database
                state.inTransaction = info.inTransaction
                state.noBackslashEscapes = info.noBackslashEscapes
                state.status = .connected
                let preferred = schema.preference(connection).defaultDatabase
                if !preferred.isEmpty, preferred != info.database {
                    let updated = try await client.useDatabase(preferred, config: connection, password: password)
                    state.currentDatabase = updated.database
                }
                await schema.discover(connection, client: client)
            } catch {
                state.status = .disconnected
                state.error = MySQLClient.message(error)
            }
        }
    }

    func disconnect(_ connection: DatabaseConnection) async -> Bool {
        let state = state(connection.id)
        guard !state.busy, state.status != .connecting else { return false }
        if state.inTransaction {
            let alert = NSAlert()
            alert.messageText = "¿Cerrar la conexión?"
            alert.informativeText = "La transacción pendiente se revertirá."
            alert.addButton(withTitle: "Cerrar conexión")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        if schema.loading.contains(connection.id) { schema.cancel(connection.id) }
        await client.disconnect(connection.id)
        state.status = .disconnected
        state.inTransaction = false
        state.error = nil
        return true
    }

    func execute(_ document: EditorDocument, connection: DatabaseConnection,
                 queryOverride: String? = nil, databaseOverride: String? = nil,
                 pageIndex: Int = 0, targetResultID: UUID? = nil) {
        let state = state(connection.id), execution = document.sqlExecution
        guard !execution.isRunning, !state.busy, state.status != .connecting else { return }
        let query: (text: String, startingLine: Int)
        do {
            query = try queryOverride.map { (text: $0, startingLine: 1) }
                ?? document.queryAtCursor(noBackslashEscapes: state.noBackslashEscapes)
        }
        catch { execution.error = MySQLClient.message(error)
        resultsVisible = true
        return }
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            execution.error = "No hay una sentencia SQL bajo el cursor."
            resultsVisible = true
            return
        }
        let retainedBytes = execution.results.reduce(0) { total, result in
            total + result.rows.reduce(0) { $0 + $1.reduce(0) { $0 + 16 + ($1?.utf8.count ?? 0) } }
        }
        let reusing = execution.results.contains {
            !execution.pinned.contains($0.id) && $0.sql.trimmingCharacters(in: .whitespacesAndNewlines) == query.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                && $0.connection == connection
        }
        guard reusing || (execution.results.count < 200 && retainedBytes < 24_000_000) else {
            execution.error = "Cerrá algunas pestañas de resultados antes de ejecutar más consultas."
            return
        }
        execution.targetResultID = targetResultID
        let targetDatabase = databaseOverride ?? (state.status == .connected ? state.currentDatabase
            : (schema.preference(connection).defaultDatabase.isEmpty ? connection.database : schema.preference(connection).defaultDatabase))
        do {
            var script = SQLScript(query.text, startingLine: query.startingLine)
            if let statement = try script.next(noBackslashEscapes: state.noBackslashEscapes) {
                var pending = SQLResult(statement: 1, line: statement.line)
                pending.sql = statement.text
                pending.connection = connection
                pending.database = targetDatabase
                if SQLPagination(statement.text, page: pageIndex, noBackslashEscapes: state.noBackslashEscapes) != nil {
                    pending.page = SQLPage(index: pageIndex)
                }
                guard execution.begin(pending) else { execution.targetResultID = nil
                return }
            }
        } catch { execution.error = MySQLClient.message(error)
        return }
        let timeoutSeconds = max(1, min(execution.timeoutSeconds, 3600))
        execution.timeoutSeconds = timeoutSeconds
        let operation = UUID()
        execution.operationID = operation
        execution.error = nil
        execution.cancelNote = nil
        execution.connectionName = connection.name
        execution.destination = state.destination(for: connection)
        execution.isRunning = true
        execution.isCancelling = false
        state.busy = true
        state.error = nil
        resultsVisible = true
        execution.task = Task {
            defer {
                execution.finish(error: execution.error)
                execution.isRunning = false
                execution.isCancelling = false
                execution.task = nil
                execution.operationID = nil
                state.busy = false
            }
            do {
                try Task.checkCancellation()
                let password = try CredentialStore.read(for: connection)
                if let databaseOverride, !databaseOverride.isEmpty {
                    _ = try await client.useDatabase(databaseOverride, config: connection, password: password)
                } else if await client.info(connection.id) == nil {
                    let preferred = schema.preference(connection).defaultDatabase
                    if !preferred.isEmpty {
                        _ = try await client.useDatabase(preferred, config: connection, password: password)
                    }
                }
                let info = try await client.execute(query.text, startingLine: query.startingLine, configuration: connection,
                                                    password: password, operation: operation, timeoutSeconds: timeoutSeconds,
                                                    pageIndex: pageIndex,
                                                    onStatement: { pending in
                    let accepted = await MainActor.run { execution.begin(pending) }
                    if !accepted { throw CancellationError() }
                }, onResult: { result in
                    await MainActor.run { execution.receive(result) }
                })
                state.status = .connected
                state.currentDatabase = info.database
                state.inTransaction = info.inTransaction
                state.noBackslashEscapes = info.noBackslashEscapes
                if schema.snapshot(connection) == nil {
                    Task { await schema.discover(connection, client: client) }
                }
            } catch {
                execution.error = MySQLClient.message(error)
                if let info = await client.info(connection.id) {
                    state.status = .connected
                    state.currentDatabase = info.database
                    state.inTransaction = info.inTransaction
                state.noBackslashEscapes = info.noBackslashEscapes
                } else {
                    state.status = .disconnected
                    state.inTransaction = false
                }
            }
        }
    }

    func selectDatabase(_ name: String, connection: DatabaseConnection) {
        let state = state(connection.id)
        guard !state.busy, state.status != .connecting else { return }
        state.busy = true
        Task {
            defer { state.busy = false }
            do {
                let password = try CredentialStore.read(for: connection)
                let info = try await client.useDatabase(name, config: connection, password: password)
                state.currentDatabase = info.database
                state.inTransaction = info.inTransaction
                state.noBackslashEscapes = info.noBackslashEscapes
                state.status = .connected
                state.error = nil
            } catch { state.error = MySQLClient.message(error) }
        }
    }

    func submit(_ draft: SQLResultDraft, profiles: [DatabaseConnection]) {
        guard let connection = draft.result.connection, profiles.contains(connection), let table = draft.table else {
            draft.error = "La conexión cambió. Ejecutá la consulta nuevamente antes de enviar."
            return
        }
        let state = state(connection.id)
        guard !state.busy else { draft.error = "La conexión está ocupada."
        return }
        do {
            let mutations = try draft.mutations()
            guard !mutations.isEmpty else { return }
            draft.sending = true
            state.busy = true
            Task {
                defer { draft.sending = false
                state.busy = false }
                do {
                    let password = try CredentialStore.read(for: connection)
                    try await client.apply(mutations, table: table, configuration: connection, password: password)
                    draft.discard()
                    draft.sent = true
                    draft.reason = "Cambios enviados. Volvé a ejecutar la consulta para actualizar los datos."
                    draft.showingReview = false
                } catch {
                    draft.error = MySQLClient.message(error)
                    if draft.error?.contains("COMMIT") == true { draft.reason = draft.error ?? "" }
                }
            }
        } catch { draft.error = MySQLClient.message(error) }
    }

    func cancel(_ execution: SQLExecution) {
        guard let operation = execution.operationID, execution.isRunning, !execution.isCancelling else { return }
        execution.isCancelling = true
        execution.task?.cancel()
        execution.cancelNote = nil
        Task {
            if case .localOnly(let reason) = await client.cancel(operation) {
                execution.cancelNote =
                    "Se cerró la conexión local, pero la consulta puede seguir en el servidor (\(reason))."
            }
        }
    }

    var hasActiveWork: Bool { states.values.contains { $0.busy || $0.inTransaction } }

    func prepareToLeave(confirmActivity: Bool = true, closeIdleConnections: Bool = true) async -> Bool {
        let hasActivity = states.values.contains { $0.busy || $0.inTransaction }
        if !closeIdleConnections && !hasActivity { return true }
        if hasActivity && confirmActivity {
            let alert = NSAlert()
            alert.messageText = "¿Cerrar las conexiones MySQL?"
            alert.informativeText = "Se cancelarán las consultas en curso y se revertirán las transacciones pendientes."
            alert.addButton(withTitle: "Cerrar conexiones")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        schema.cancelAll()
        await client.closeAll()
        for state in states.values {
            state.status = .disconnected
            state.inTransaction = false
        }
        return true
    }
}
