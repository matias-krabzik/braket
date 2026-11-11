@testable import Krabzik
import MySQLNIO
import NIOSSL
import XCTest

/// La cola de errores y la única función que los traduce a texto.
///
/// Antes había dos caminos —`MySQLClient.message(_:)` y `error.localizedDescription`— y un
/// hueco único donde el segundo error pisaba al primero.
/// Ver docs/specs/C5-dividir-workspacecontroller.md.
@MainActor
final class ErrorCenterTests: XCTestCase {
    func testTwoErrorsInTheSameCycleAreBothKept() {
        let center = ErrorCenter()
        center.report(DatabaseFailure("no se pudo guardar"))
        center.report(WorkspaceError.externalChange)

        XCTAssertEqual(center.current?.message, "no se pudo guardar", "se muestra el primero")
        XCTAssertEqual(center.pending, 1)

        center.dismissFirst()
        XCTAssertEqual(center.current?.message, WorkspaceError.externalChange.errorDescription)
        XCTAssertEqual(center.pending, 0)

        center.dismissFirst()
        XCTAssertNil(center.current)
    }

    func testDismissAllEmptiesTheQueue() {
        let center = ErrorCenter()
        for index in 0 ..< 5 { center.report(DatabaseFailure("fallo \(index)")) }
        XCTAssertEqual(center.pending, 4)
        center.dismissAll()
        XCTAssertNil(center.current)
        XCTAssertEqual(center.pending, 0)
    }

    /// Una avalancha no puede tapar el primero, que suele ser la causa.
    func testQueueIsBounded() {
        let center = ErrorCenter()
        for index in 0 ..< 50 { center.report(DatabaseFailure("fallo \(index)")) }
        XCTAssertEqual(center.queue.count, ErrorCenter.limit)
        XCTAssertEqual(center.current?.message, "fallo 0", "se conserva el primero, no el último")
    }

    func testAppMessageNeedsNoErrorType() {
        let center = ErrorCenter()
        center.report(message: "El proyecto está en solo lectura.")
        XCTAssertEqual(center.current?.message, "El proyecto está en solo lectura.")
    }

    /// Criterio 4 de C5: los cuatro tipos dan el mismo texto por cualquier camino.
    func testDescribeCoversTheFourKindsOfError() {
        XCTAssertEqual(AppError.describe(DatabaseFailure("tabla inexistente")), "tabla inexistente")
        XCTAssertEqual(AppError.describe(AgentFailure("Codex no respondió")), "Codex no respondió")
        XCTAssertEqual(AppError.describe(WorkspaceError.unsupportedVersion),
                       "La versión de este proyecto no es compatible.")
        XCTAssertEqual(AppError.describe(CancellationError()),
                       "Ejecución cancelada. La conexión se cerró.")

        // Un error de MySQLNIO no tiene `errorDescription`: sin la rama propia saldría
        // como «The operation couldn't be completed».
        let mysql = MySQLError.protocolError
        XCTAssertEqual(AppError.describe(mysql), mysql.description)
        XCTAssertFalse(AppError.describe(mysql).contains("couldn't be completed"))
    }

    /// La ruta de base de datos y la general tienen que decir lo mismo.
    func testDatabasePathAndGeneralPathAgree() {
        for error in [DatabaseFailure("x") as Error, CancellationError(), MySQLError.protocolError] {
            XCTAssertEqual(MySQLClient.message(error), AppError.describe(error))
        }
    }

    func testContextIsRecorded() {
        let center = ErrorCenter()
        center.report(DatabaseFailure("algo"), context: "alTocarElBoton")
        XCTAssertEqual(center.current?.context, "alTocarElBoton")
    }

    func testTLSHandshakeFailurePreservesTheCauseInsteadOfNSErrorCodeZero() {
        let error = NIOSSLError.handshakeFailed(.sslError([.eofDuringHandshake]))
        XCTAssertEqual((error as NSError).code, 0, "Es el error opaco reportado por la interfaz")
        let description = AppError.describe(error)
        XCTAssertTrue(description.contains("negociación TLS"))
        XCTAssertTrue(description.contains("VPN"))
        XCTAssertFalse(description.contains("NIOSSL.NIOSSLError"))
        XCTAssertEqual(MySQLClient.message(error), description)
    }

    func testTLSHostnameAndCertificateErrorsHaveDifferentGuidance() {
        XCTAssertTrue(AppError.describe(NIOSSLExtraError.failedToValidateHostname).contains("no corresponde"))
        XCTAssertTrue(AppError.describe(NIOSSLError.unableToValidateCertificate).contains("su CA"))
        XCTAssertTrue(AppError.describe(NIOSSLError.uncleanShutdown).contains("cerró"))
        let unknown = AppError.describe(NIOSSLError.handshakeFailed(.wantRead))
        XCTAssertTrue(unknown.contains("wantRead"), "Los fallos desconocidos deben conservar el detalle técnico")
    }
}
