import AppKit
import Observation

/// La contraseña se lee del llavero justo antes de usarla y viaja como parámetro.
/// NO se guarda en el estado observable ni en `SQLExecution`, aunque sería cómodo
/// para no releerla: acotar su vida es el punto de docs/specs/S4-no-retener-password.md.
@MainActor @Observable
final class DatabaseController {
    var selectedConnectionID: UUID?
    var editingConnection: DatabaseConnection?
    var states: [UUID: DatabaseState] = [:]
    var resultsVisible = true
    @ObservationIgnored let client = MySQLClient()
    @ObservationIgnored private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    func state(_ id: UUID) -> DatabaseState {
        if let state = states[id] { return state }
        let state = DatabaseState()
        states[id] = state
        return state
    }

    func install(_ connections: [DatabaseConnection]) {
        states = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, DatabaseState()) })
        selectedConnectionID = connections.first?.id
    }

    func connect(_ connection: DatabaseConnection) {
        selectedConnectionID = connection.id
        let state = state(connection.id)
        guard state.status == .disconnected, !state.busy else { return }
        state.status = .connecting; state.error = nil
        connectionTasks[connection.id] = Task {
            defer { connectionTasks.removeValue(forKey: connection.id) }
            do {
                let password = try CredentialStore.read(for: connection)
                let info = try await client.connect(connection, password: password)
                state.currentDatabase = info.database
                state.inTransaction = info.inTransaction
                state.status = .connected
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
        await client.disconnect(connection.id)
        state.status = .disconnected; state.inTransaction = false; state.error = nil
        return true
    }

    func execute(_ document: EditorDocument, connection: DatabaseConnection) {
        let state = state(connection.id), execution = document.sqlExecution
        guard !execution.isRunning, !state.busy, state.status != .connecting else { return }
        let query = document.sqlToExecute
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let operation = UUID()
        execution.operationID = operation
        execution.results = []; execution.selectedResultID = nil; execution.error = nil
        execution.cancelNote = nil
        execution.connectionName = connection.name
        execution.destination = connection.destination
        execution.isRunning = true; execution.isCancelling = false
        state.busy = true; state.error = nil
        resultsVisible = true
        execution.task = Task {
            defer { execution.isRunning = false; execution.isCancelling = false; execution.task = nil; execution.operationID = nil; state.busy = false }
            do {
                try Task.checkCancellation()
                let password = try CredentialStore.read(for: connection)
                let info = try await client.execute(query.text, startingLine: query.startingLine, configuration: connection,
                                                    password: password, operation: operation) { result in
                    await MainActor.run {
                        execution.results.append(result)
                        execution.selectedResultID = result.id
                    }
                }
                state.status = .connected
                state.currentDatabase = info.database
                state.inTransaction = info.inTransaction
            } catch {
                execution.error = MySQLClient.message(error)
                if let info = await client.info(connection.id) {
                    state.status = .connected; state.currentDatabase = info.database; state.inTransaction = info.inTransaction
                } else { state.status = .disconnected; state.inTransaction = false }
            }
        }
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

    func prepareToLeave() async -> Bool {
        let hasActivity = states.values.contains { $0.busy || $0.inTransaction }
        if hasActivity {
            let alert = NSAlert()
            alert.messageText = "¿Cerrar las conexiones MySQL?"
            alert.informativeText = "Se cancelarán las consultas en curso y se revertirán las transacciones pendientes."
            alert.addButton(withTitle: "Cerrar conexiones")
            alert.addButton(withTitle: "Cancelar")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        await client.closeAll()
        for state in states.values { state.status = .disconnected; state.inTransaction = false }
        return true
    }
}
