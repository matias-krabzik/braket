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
    /// Cómo se pide la confirmación de escritura, con el destino ya redactado. Es un punto
    /// de inyección a propósito: un `NSAlert` modal no se puede ejercitar en una prueba
    /// —cuelga la corrida—, así que las pruebas reemplazan la pregunta y comprueban que se
    /// haga una vez por ejecución. El diálogo real se arma en `writeAlert(...)`, que sí se
    /// prueba.
    @ObservationIgnored
    var askBeforeWriting: (SQLWriteGuard.Audit, DatabaseConnection, String) -> Bool = { audit, connection, destination in
        // `DatabaseController` y no `Self`: en el inicializador de una propiedad almacenada
        // no se puede nombrar el tipo covariante.
        DatabaseController.writeAlert(audit, connection: connection, destination: destination)
            .runModal() == .alertFirstButtonReturn
    }
    /// Las otras dos preguntas modales de la base, con el mismo criterio que
    /// `askBeforeWriting`: un `NSAlert` real no se puede ejercitar en una prueba, así que
    /// el diálogo se arma en un método estático —que sí se prueba— y acá queda el punto
    /// donde se engancha. Un escenario de QA los contesta por guion y el registro deja
    /// escrito qué se preguntó y qué se respondió.
    @ObservationIgnored
    var confirmDisconnectWithTransaction: (DatabaseConnection) -> Bool = { _ in
        DatabaseController.disconnectAlert().runModal() == .alertFirstButtonReturn
    }
    @ObservationIgnored
    var confirmCloseActiveConnections: () -> Bool = {
        DatabaseController.closeConnectionsAlert().runModal() == .alertFirstButtonReturn
    }
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
        QAProbe.action("connection.connect.request", ["name": connection.name,
                                                      "status": state.qaStatus,
                                                      "busy": QAField.bool(state.busy)])
        guard state.status == .disconnected, !state.busy else {
            QAProbe.sql("connection.connect.ignored", ["name": connection.name, "status": state.qaStatus])
            return
        }
        state.status = .connecting
        state.error = nil
        QAProbe.state("state.connection", state.qaFields(connection))
        connectionTasks[connection.id] = Task {
            defer { connectionTasks.removeValue(forKey: connection.id) }
            do {
                let password = try CredentialStore.read(for: connection)
                let info = try await client.connect(connection, password: password)
                state.currentDatabase = info.database
                state.inTransaction = info.inTransaction
                state.noBackslashEscapes = info.noBackslashEscapes
                state.status = .connected
                QAProbe.sql("connection.connect.ok", state.qaFields(connection))
                let preferred = schema.preference(connection).defaultDatabase
                if !preferred.isEmpty, preferred != info.database {
                    let updated = try await client.useDatabase(preferred, config: connection, password: password)
                    state.currentDatabase = updated.database
                }
                await schema.discover(connection, client: client)
            } catch {
                state.status = .disconnected
                state.error = MySQLClient.message(error)
                QAProbe.failure("connection.connect.failed", state.error ?? "", ["name": connection.name])
            }
            QAProbe.state("state.connection", state.qaFields(connection))
        }
    }

    func disconnect(_ connection: DatabaseConnection) async -> Bool {
        let state = state(connection.id)
        QAProbe.action("connection.disconnect.request", state.qaFields(connection))
        guard !state.busy, state.status != .connecting else {
            QAProbe.sql("connection.disconnect.ignored", ["name": connection.name, "status": state.qaStatus])
            return false
        }
        if state.inTransaction {
            let confirmed = confirmDisconnectWithTransaction(connection)
            QAProbe.dialog("dialog.connection.disconnectWithTransaction",
                           answer: confirmed ? "close" : "cancel", ["name": connection.name])
            guard confirmed else { return false }
        }
        if schema.loading.contains(connection.id) { schema.cancel(connection.id) }
        await client.disconnect(connection.id)
        state.status = .disconnected
        state.inTransaction = false
        state.error = nil
        QAProbe.sql("connection.disconnect.ok", state.qaFields(connection))
        QAProbe.state("state.connection", state.qaFields(connection))
        return true
    }

    /// El diálogo que avisa que cerrar la conexión revierte la transacción abierta.
    static func disconnectAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "¿Cerrar la conexión?"
        alert.informativeText = "La transacción pendiente se revertirá."
        alert.addButton(withTitle: "Cerrar conexión")
        alert.addButton(withTitle: "Cancelar")
        return alert
    }

    /// El diálogo que pregunta antes de cortar consultas y transacciones en curso.
    static func closeConnectionsAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "¿Cerrar las conexiones MySQL?"
        alert.informativeText = "Se cancelarán las consultas en curso y se revertirán las transacciones pendientes."
        alert.addButton(withTitle: "Cerrar conexiones")
        alert.addButton(withTitle: "Cancelar")
        return alert
    }

    func execute(_ document: EditorDocument, connection: DatabaseConnection,
                 queryOverride: String? = nil, databaseOverride: String? = nil,
                 pageIndex: Int = 0, targetResultID: UUID? = nil) {
        let state = state(connection.id), execution = document.sqlExecution
        QAProbe.action("sql.execute.request", ["file": QAField.path(document.url),
                                               "connection": connection.name,
                                               "override": QAField.bool(queryOverride != nil),
                                               "databaseOverride": databaseOverride ?? "",
                                               "page": QAField.count(pageIndex),
                                               "status": state.qaStatus])
        guard !execution.isRunning, !state.busy, state.status != .connecting else {
            QAProbe.sql("sql.execute.ignored", ["reason": execution.isRunning ? "running" : "busy"])
            return
        }
        let query: (text: String, startingLine: Int)
        do {
            query = try queryOverride.map { (text: $0, startingLine: 1) }
                ?? document.queryAtCursor(noBackslashEscapes: state.noBackslashEscapes)
        }
        catch { execution.error = MySQLClient.message(error)
        resultsVisible = true
        QAProbe.failure("sql.execute.rejected", execution.error ?? "", ["stage": "cursor"])
        return }
        guard !query.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            execution.error = "No hay una sentencia SQL bajo el cursor."
            resultsVisible = true
            QAProbe.failure("sql.execute.rejected", execution.error ?? "", ["stage": "empty"])
            return
        }
        guard allowsExecution(query, connection: connection, state: state, execution: execution) else { return }
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
            QAProbe.failure("sql.execute.rejected", execution.error ?? "",
                            ["stage": "budget", "results": QAField.count(execution.results.count),
                             "bytes": QAField.count(retainedBytes)])
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
                QAProbe.sql("sql.execute.cancelledByDraft", ["sql": QAField.sql(statement.text)])
                return }
            }
        } catch { execution.error = MySQLClient.message(error)
        QAProbe.failure("sql.execute.rejected", execution.error ?? "", ["stage": "split"])
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
        QAProbe.sql("sql.execute.begin", ["sql": QAField.sql(query.text), "line": QAField.count(query.startingLine),
                                          "connection": connection.name, "database": targetDatabase,
                                          "timeout": QAField.count(timeoutSeconds)])
        execution.task = Task {
            defer {
                execution.finish(error: execution.error)
                execution.isRunning = false
                execution.isCancelling = false
                execution.task = nil
                execution.operationID = nil
                state.busy = false
                QAProbe.sql(execution.error == nil ? "sql.execute.ok" : "sql.execute.failed", execution.qaFields)
                QAProbe.state("state.execution", execution.qaFields)
                QAProbe.state("state.connection", state.qaFields(connection))
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
                    await MainActor.run {
                        execution.receive(result)
                        QAProbe.sql("sql.result", ["sql": QAField.sql(result.sql),
                                                   "columns": QAField.count(result.columns.count),
                                                   "rows": QAField.count(result.rows.count),
                                                   "affected": QAField.count(Int(result.affectedRows)),
                                                   "truncated": QAField.bool(result.truncated),
                                                   "error": QAField.text(result.error ?? "")])
                    }
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

    /// Aplica la política de escritura del perfil **antes** de cualquier trabajo de
    /// conexión: acá todavía no se leyó el llavero ni se abrió una sesión, así que un
    /// perfil en solo lectura rechaza sin tocar el servidor. Ver
    /// docs/specs/S8-guarda-de-escritura-mysql.md.
    ///
    /// Devuelve `false` cuando no hay que ejecutar, y deja el motivo en `execution.error`
    /// salvo cuando el usuario canceló el diálogo: eso no necesita explicación.
    private func allowsExecution(_ query: (text: String, startingLine: Int), connection: DatabaseConnection,
                                 state: DatabaseState, execution: SQLExecution) -> Bool {
        // `unrestricted` no clasifica nada: el camino tiene que ser exactamente el de
        // antes de que existiera la guarda, incluido cómo se informa un script que no se
        // puede partir.
        guard connection.effectiveWritePolicy != .unrestricted else { return true }
        let audit: SQLWriteGuard.Audit
        do {
            audit = try SQLWriteGuard.audit(query.text, startingLine: query.startingLine,
                                            noBackslashEscapes: state.noBackslashEscapes)
        } catch {
            execution.error = MySQLClient.message(error)
            resultsVisible = true
            return false
        }
        guard audit.hasWrites else { return true }
        QAProbe.sql("sql.writeGuard.writes", ["policy": connection.effectiveWritePolicy.rawValue,
                                              "writes": QAField.count(audit.writes.count),
                                              "total": QAField.count(audit.total)])
        guard connection.effectiveWritePolicy != .readOnly else {
            execution.error = Self.rejection(audit, connection: connection)
            resultsVisible = true
            QAProbe.failure("sql.writeGuard.rejected", execution.error ?? "", ["connection": connection.name])
            return false
        }
        let approved = askBeforeWriting(audit, connection, state.destination(for: connection))
        QAProbe.dialog("dialog.sql.confirmWrites", answer: approved ? "run" : "cancel",
                       ["connection": connection.name, "writes": QAField.count(audit.writes.count)])
        return approved
    }

    private static func rejection(_ audit: SQLWriteGuard.Audit, connection: DatabaseConnection) -> String {
        let detail = audit.writes.count == 1
            ? "la sentencia escribe"
            : "\(audit.writes.count) de \(audit.total) sentencias escriben"
        let first = audit.preview(limit: 1).first.map { $0 + ". " } ?? ""
        return "No se ejecutó nada: el perfil «\(connection.name)» está en solo lectura y \(detail). "
            + first + "No se abrió ninguna conexión."
    }

    /// El diálogo que pregunta antes de mandar un script que escribe. Dice a dónde va,
    /// cuántas sentencias escriben y cuáles son las primeras.
    ///
    /// La pregunta es **por ejecución**: no se recuerda la respuesta ni para la próxima
    /// ejecución ni para el resto de la sesión, así que no hay nada que guardar acá.
    static func writeAlert(_ audit: SQLWriteGuard.Audit, connection: DatabaseConnection,
                           destination: String) -> NSAlert {
        let shown = 3
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = audit.writes.count == 1
            ? "¿Ejecutar una sentencia que escribe?"
            : "¿Ejecutar \(audit.writes.count) sentencias que escriben?"
        let rest = audit.writes.count > shown ? "\n… y \(audit.writes.count - shown) más." : ""
        alert.informativeText = "Destino: \(connection.name) · \(destination)\n"
            + "El script tiene \(audit.total) sentencias en total.\n\n"
            + audit.preview(limit: shown).joined(separator: "\n") + rest
        let run = alert.addButton(withTitle: "Ejecutar")
        let cancel = alert.addButton(withTitle: "Cancelar")
        run.hasDestructiveAction = true
        // El botón destructivo no es el predeterminado: ⏎ cancela.
        run.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert
    }

    func selectDatabase(_ name: String, connection: DatabaseConnection) {
        let state = state(connection.id)
        QAProbe.action("connection.useDatabase.request", ["name": connection.name, "database": name,
                                                          "status": state.qaStatus])
        guard !state.busy, state.status != .connecting else {
            QAProbe.sql("connection.useDatabase.ignored", ["name": connection.name])
            return
        }
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
                QAProbe.sql("connection.useDatabase.ok", state.qaFields(connection))
            } catch {
                state.error = MySQLClient.message(error)
                QAProbe.failure("connection.useDatabase.failed", state.error ?? "", ["name": connection.name])
            }
            QAProbe.state("state.connection", state.qaFields(connection))
        }
    }

    func submit(_ draft: SQLResultDraft, profiles: [DatabaseConnection]) {
        QAProbe.action("grid.submit.request", draft.qaFields)
        guard let connection = draft.result.connection, profiles.contains(connection), let table = draft.table else {
            draft.error = "La conexión cambió. Ejecutá la consulta nuevamente antes de enviar."
            QAProbe.failure("grid.submit.rejected", draft.error ?? "", ["stage": "connection"])
            return
        }
        guard connection.effectiveWritePolicy != .readOnly else {
            draft.error = "El perfil «\(connection.name)» está en solo lectura: no se envían cambios."
            QAProbe.failure("grid.submit.rejected", draft.error ?? "", ["stage": "writePolicy"])
            return
        }
        let state = state(connection.id)
        guard !state.busy else { draft.error = "La conexión está ocupada."
        QAProbe.failure("grid.submit.rejected", draft.error ?? "", ["stage": "busy"])
        return }
        do {
            let mutations = try draft.mutations()
            QAProbe.sql("grid.submit.plan", ["table": table.qualified, "statements": QAField.count(mutations.count),
                                             "sql": QAField.sql(mutations.map(\.sql).joined(separator: "; "), limit: 400)])
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
                    QAProbe.sql("grid.submit.ok", draft.qaFields)
                } catch {
                    draft.error = MySQLClient.message(error)
                    if draft.error?.contains("COMMIT") == true { draft.reason = draft.error ?? "" }
                    QAProbe.failure("grid.submit.failed", draft.error ?? "", ["table": table.qualified])
                }
                QAProbe.state("state.draft", draft.qaFields)
            }
        } catch {
            draft.error = MySQLClient.message(error)
            QAProbe.failure("grid.submit.rejected", draft.error ?? "", ["stage": "mutations"])
        }
    }

    func cancel(_ execution: SQLExecution) {
        QAProbe.action("sql.cancel.request", execution.qaFields)
        guard let operation = execution.operationID, execution.isRunning, !execution.isCancelling else { return }
        execution.isCancelling = true
        execution.task?.cancel()
        execution.cancelNote = nil
        Task {
            if case .localOnly(let reason) = await client.cancel(operation) {
                execution.cancelNote =
                    "Se cerró la conexión local, pero la consulta puede seguir en el servidor (\(reason))."
                QAProbe.sql("sql.cancel.localOnly", ["reason": QAField.text(reason)])
            } else {
                QAProbe.sql("sql.cancel.ok")
            }
        }
    }

    var hasActiveWork: Bool { states.values.contains { $0.busy || $0.inTransaction } }

    func prepareToLeave(confirmActivity: Bool = true, closeIdleConnections: Bool = true) async -> Bool {
        let hasActivity = states.values.contains { $0.busy || $0.inTransaction }
        if !closeIdleConnections && !hasActivity { return true }
        if hasActivity && confirmActivity {
            let confirmed = confirmCloseActiveConnections()
            QAProbe.dialog("dialog.connection.closeActive", answer: confirmed ? "close" : "cancel")
            guard confirmed else { return false }
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
