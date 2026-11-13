import Foundation
import MySQLNIO
import NIOSSL
import Observation

/// Un error ya traducido a lo que se le muestra al usuario.
struct AppError: Identifiable, Sendable {
    let id = UUID()
    /// El texto que se muestra. Sale de `AppError.describe(_:)`.
    let message: String
    /// Desde dónde se reportó. No se muestra: va al log, para poder ubicarlo.
    let context: String
    let date = Date()
}

extension AppError {
    /// El texto de un error, con una sola regla para toda la app.
    ///
    /// Antes había dos caminos: `MySQLClient.message(_:)`, que entendía los errores de la
    /// base, y `error.localizedDescription` para todo lo demás. El mismo error contaba dos
    /// cosas distintas según por dónde llegara —un `MySQLError` por el camino general
    /// salía como «The operation couldn't be completed»—. Ahora esta es la única.
    nonisolated static func describe(_ error: Error) -> String {
        if error is CancellationError { return "Ejecución cancelada. La conexión se cerró." }
        // Los errores propios (DatabaseFailure, AgentFailure, WorkspaceError) ya traen el
        // mensaje redactado para el usuario.
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        if let mysql = error as? MySQLError { return mysql.description }
        if let tls = error as? NIOSSLError { return describeTLS(tls) }
        if let tls = error as? NIOSSLExtraError {
            switch tls {
            case .failedToValidateHostname:
                return "El certificado TLS no corresponde al servidor indicado. Usá el nombre incluido en el certificado."
            case .cannotUseIPAddressInSNI:
                return "No se pudo iniciar TLS con esa dirección IP. Usá el nombre de servidor incluido en el certificado."
            case .invalidSNIHostname, .serverHostnameImpossibleToMatch:
                return "El nombre de servidor no es válido para TLS. Revisá el campo Servidor."
            default:
                return "No se pudo completar la conexión TLS. Detalle: \(tls)"
            }
        }
        return error.localizedDescription
    }

    private nonisolated static func describeTLS(_ error: NIOSSLError) -> String {
        switch error {
        case .handshakeFailed(let cause):
            let detail = String(describing: cause)
            if detail.contains("CERTIFICATE_VERIFY_FAILED") {
                return "No se pudo verificar el certificado TLS de MySQL. "
                    + "Revisá el nombre del servidor, la vigencia y la confianza en su CA. "
                    + "En Editar conexión podés indicar la CA en Parámetros avanzados, "
                    + "elegir Exigir SSL (sin verificar certificado) o Usar SSL si está disponible."
            }
            if detail.contains("EOF during handshake") || cause == .zeroReturn || cause == .syscallError {
                return "La conexión se cerró durante la negociación TLS. Revisá el TLS del servidor y la conexión por VPN."
            }
            return "No se pudo negociar TLS con MySQL. Revisá la configuración TLS del servidor. Detalle: \(cause)"
        case .unableToValidateCertificate, .noCertificateToValidate:
            return "No se pudo validar el certificado TLS de MySQL. Revisá el certificado del servidor y su CA."
        case .uncleanShutdown, .shutdownFailed:
            return "La conexión TLS se cerró de forma inesperada. Revisá la conexión por VPN y el estado del servidor."
        default:
            return "No se pudo completar la conexión TLS. Detalle: \(error)"
        }
    }
}

/// La cola de errores que la ventana tiene para mostrar.
///
/// Es una cola y no un hueco único porque dos errores en el mismo ciclo —guardar falla y
/// el proceso muere— son dos cosas que el usuario necesita saber, y antes la segunda
/// pisaba a la primera sin dejar rastro. Todo lo que entra queda además en el log con el
/// contexto, así que un error que el usuario descartó sigue siendo investigable.
///
/// Confinado al main actor. Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor @Observable
final class ErrorCenter {
    /// Tope de la cola. Más que esto no es información, es una avalancha: se descartan
    /// los nuevos para no tapar el primero, que suele ser la causa.
    static let limit = 20

    private(set) var queue: [AppError] = []

    /// El que se está mostrando.
    var current: AppError? { queue.first }
    /// Cuántos esperan detrás del que se muestra.
    var pending: Int { max(0, queue.count - 1) }

    func report(_ error: Error, context: StaticString = #function) {
        let entry = AppError(message: AppError.describe(error), context: "\(context)")
        Log.workspace.error("""
            error en \(entry.context, privacy: .public): \
            \(entry.message, privacy: .private)
            """)
        guard queue.count < Self.limit else { return }
        queue.append(entry)
    }

    /// Mensaje propio de la app, sin un `Error` detrás.
    func report(message: String, context: StaticString = #function) {
        report(AppMessage(message), context: context)
    }

    func dismissFirst() {
        if !queue.isEmpty { queue.removeFirst() }
    }

    func dismissAll() { queue.removeAll() }
}

/// Envoltorio para reportar un mensaje que la app redacta, sin inventar un tipo de error
/// por cada caso.
private struct AppMessage: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
