import Foundation

/// Cómo se fotografía cada pieza de estado observable en el registro de QA.
///
/// Está junto —y no repartido por cada servicio— por el mismo motivo que `QAField`: la
/// regla de privacidad y el nombre de cada campo se revisan leyendo un archivo. Lo que
/// una prueba afirma es exactamente lo que se escribe acá, así que agregar un campo es
/// agregar algo que se puede afirmar.
extension DatabaseState {
    var qaStatus: String {
        switch status {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        }
    }

    func qaFields(_ connection: DatabaseConnection) -> [String: String] {
        ["name": connection.name,
         "status": qaStatus,
         "destination": destination(for: connection),
         "database": currentDatabase,
         "busy": QAField.bool(busy),
         "inTransaction": QAField.bool(inTransaction),
         "writePolicy": connection.effectiveWritePolicy.rawValue,
         "error": QAField.text(error ?? "")]
    }
}

extension SQLExecution {
    var qaFields: [String: String] {
        ["running": QAField.bool(isRunning),
         "cancelling": QAField.bool(isCancelling),
         "results": QAField.count(results.count),
         "pinned": QAField.count(pinned.count),
         "timeout": QAField.count(timeoutSeconds),
         "connection": connectionName,
         "destination": destination,
         "error": QAField.text(error ?? ""),
         "selectedRows": QAField.count(selectedResult?.rows.count ?? 0),
         "selectedError": QAField.text(selectedResult?.error ?? "")]
    }
}

extension SQLResultDraft {
    /// El estado de la grilla: si deja editar y por qué no, y qué hay pendiente de enviar.
    var qaFields: [String: String] {
        ["table": table?.qualified ?? "",
         "canEdit": QAField.bool(canEdit),
         "canInsert": QAField.bool(canInsert),
         "reason": QAField.text(reason),
         "editing": QAField.bool(isEditingCell),
         "changes": QAField.count(changes.count),
         "inserted": QAField.count(inserted.count),
         "deleted": QAField.count(deleted.count),
         "hasChanges": QAField.bool(hasChanges),
         "sending": QAField.bool(sending),
         "sent": QAField.bool(sent),
         "review": QAField.bool(showingReview),
         "error": QAField.text(error ?? "")]
    }
}

extension TrustDecision {
    var qaAnswer: String {
        switch self {
        case .cancel: "cancel"
        case .readOnly: "readOnly"
        case .trust: "trust"
        }
    }
}

extension SaveDecision {
    var qaAnswer: String {
        switch self {
        case .save: "save"
        case .discard: "discard"
        case .cancel: "cancel"
        }
    }
}
