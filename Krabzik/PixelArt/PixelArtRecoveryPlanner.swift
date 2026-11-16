import Foundation

/// Cómo está el archivo original de un trabajo recuperable, comprobado por quien lo ofrece (PXA-08 §5).
enum PixelArtOriginalState: Equatable, Sendable {
    /// El trabajo era un borrador: no hay original.
    case notApplicable
    /// El archivo existe y su huella coincide con la base del registro.
    case matchesBase
    /// El archivo existe pero cambió desde la base.
    case changed
    /// El archivo falta o no se puede leer.
    case missing
    /// Esa ubicación ya está abierta en esta ventana: no se crea otro editor.
    case alreadyOpen
}

/// Qué hacer con un trabajo recuperable. Es una decisión pura: nunca borra, escribe ni abre nada.
struct PixelArtRecoveryPlan: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case originalChanged
        case originalMissing
        case chainNotProven
    }

    enum Action: Equatable, Sendable {
        /// Recuperar en la instancia asociada al archivo, con los cambios pendientes sobre el original.
        case recoverInPlace
        /// Copia independiente: otro documento-ID y un nombre `…-recuperado.pxa`. Nunca toca el original.
        case recoverAsCopy(name: String, reason: Reason)
        /// Borrador con su nombre e historia; la ubicación se pide al guardar.
        case recoverDraft
        /// Solo había estado de vista de un contenido ya guardado: se recupera la vista, no «trabajo perdido».
        case restoreViewOnly
        /// La ubicación ya está abierta: se enfoca esa sesión y sus cambios se resuelven antes de sustituir nada.
        case focusOpenSession
        /// Ninguna generación válida: se informa y se conservan los candidatos. No se abre un lienzo vacío.
        case unrecoverable
    }

    var action: Action
    /// Generación elegida; `nil` solo si no hay ninguna válida.
    var snapshot: PixelArtRecoverySnapshot?
    /// La más nueva estaba dañada y se ofrece la anterior: la interfaz tiene que avisar de su generación y fecha.
    var fellBackToOlder: Bool
}

enum PixelArtRecoveryPlanner {
    static func plan(record: PixelArtRecoveryRecord, valid: [PixelArtRecoverySnapshot],
                     original: PixelArtOriginalState) -> PixelArtRecoveryPlan {
        guard let chosen = valid.first else {
            return PixelArtRecoveryPlan(action: .unrecoverable, snapshot: nil, fellBackToOlder: false)
        }
        let fellBack = record.snapshots.first.map { $0.generation != chosen.generation } ?? false
        func plan(_ action: PixelArtRecoveryPlan.Action) -> PixelArtRecoveryPlan {
            PixelArtRecoveryPlan(action: action, snapshot: chosen, fellBackToOlder: fellBack)
        }
        if original == .alreadyOpen { return plan(.focusOpenSession) }
        if record.isDraft || original == .notApplicable { return plan(.recoverDraft) }
        if valid.allSatisfy({ $0.changeClass == .viewOnly }) { return plan(.restoreViewOnly) }
        let name = copyName(for: record)
        switch original {
        case .changed: return plan(.recoverAsCopy(name: name, reason: .originalChanged))
        case .missing: return plan(.recoverAsCopy(name: name, reason: .originalMissing))
        default: break
        }
        if chosen.independent { return plan(.recoverAsCopy(name: name, reason: .chainNotProven)) }
        return plan(.recoverInPlace)
    }

    /// `nombre.pxa` → `nombre-recuperado.pxa`. Siempre termina en `.pxa` y nunca lleva componentes de ruta.
    static func copyName(for record: PixelArtRecoveryRecord) -> String {
        let source = record.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? record.suggestedName
        var stem = (source as NSString).deletingPathExtension
        stem = stem.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if stem.isEmpty || stem == "." || stem == ".." { stem = "Sin título" }
        return "\(stem)-recuperado.pxa"
    }

    /// Un guardado correcto seguido de una caída antes de limpiar no se ofrece como trabajo perdido: si la generación más
    /// nueva es byte a byte lo que quedó en disco, ya está guardada. Sin pruebas, se conserva el candidato.
    static func isAlreadyOnDisk(_ record: PixelArtRecoveryRecord, current: PixelArtFileFingerprint?) -> Bool {
        guard let current, let newest = record.snapshots.first else { return false }
        return newest.byteCount == current.size && newest.sha256 == current.sha256
    }
}
