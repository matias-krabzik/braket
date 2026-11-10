@testable import Krabzik
import MySQLNIO
import NIOCore
import XCTest

/// Paquetes sintéticos del protocolo de texto de MySQL.
///
/// `MySQLTextCommand` solo se ejercitaba contra un servidor real, es decir: en las seis
/// pruebas que se saltan por defecto. Es un decodificador con aritmética de longitudes,
/// detección de EOF ambigua y contabilidad de bytes para los límites, y el fork local del
/// cliente (Vendor/MySQLNIO) lo hace más importante, no menos. Estas pruebas no usan red
/// ni servidor. Ver docs/specs/C9-cobertura-pruebas.md.
final class MySQLProtocolTests: XCTestCase {
    private let allocator = ByteBufferAllocator()

    // MARK: - Armado de paquetes

    private func packet(_ bytes: [UInt8]) -> MySQLPacket {
        var buffer = allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return MySQLPacket(payload: buffer)
    }

    /// Entero con longitud codificada, en los cuatro anchos del protocolo.
    private func lenenc(_ value: Int) -> [UInt8] {
        switch value {
        case 0 ... 250:
            return [UInt8(value)]
        case 251 ... 0xFFFF:
            return [252, UInt8(value & 0xFF), UInt8(value >> 8)]
        case 0x1_0000 ... 0xFF_FFFF:
            return [253, UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)]
        default:
            return [254] + stride(from: 0, to: 64, by: 8).map { UInt8((value >> $0) & 0xFF) }
        }
    }

    private func text(_ value: String) -> [UInt8] { lenenc(value.utf8.count) + Array(value.utf8) }

    /// Definición de columna: catálogo, esquema, tabla, tabla original, nombre, nombre
    /// original, longitud de los campos fijos, charset, longitud y tipo.
    private func column(_ name: String, charset: UInt16 = 255, type: UInt8 = 253) -> [UInt8] {
        text("def") + text("db") + text("t") + text("t") + text(name) + text(name)
            + lenenc(12) + [UInt8(charset & 0xFF), UInt8(charset >> 8)]
            + [0, 0, 1, 0] + [type] + [0, 0, 0]
    }

    private func okPacket(affected: Int = 0, status: UInt16 = 0, warnings: UInt16 = 0) -> [UInt8] {
        [0x00] + lenenc(affected) + lenenc(0)
            + [UInt8(status & 0xFF), UInt8(status >> 8)]
            + [UInt8(warnings & 0xFF), UInt8(warnings >> 8)]
    }

    /// Fin del conjunto de filas con `CLIENT_DEPRECATE_EOF`: un paquete OK que empieza
    /// con 0xFE en vez de un EOF. Es la diferencia que hace ambigua la detección de fin.
    private func endOfRows(affected: Int = 0, status: UInt16 = 0, warnings: UInt16 = 0) -> [UInt8] {
        [0xFE] + lenenc(affected) + lenenc(0)
            + [UInt8(status & 0xFF), UInt8(status >> 8)]
            + [UInt8(warnings & 0xFF), UInt8(warnings >> 8)]
    }

    private func eofPacket(status: UInt16 = 0, warnings: UInt16 = 0) -> [UInt8] {
        [0xFE, UInt8(warnings & 0xFF), UInt8(warnings >> 8), UInt8(status & 0xFF), UInt8(status >> 8)]
    }

    private func row(_ cells: [[UInt8]?]) -> [UInt8] {
        cells.flatMap { cell -> [UInt8] in
            guard let cell else { return [0xFB] }
            return lenenc(cell.count) + cell
        }
    }

    private var modern: MySQLProtocol.CapabilityFlags { .clientDefault }
    private var legacy: MySQLProtocol.CapabilityFlags {
        var flags = MySQLProtocol.CapabilityFlags.clientDefault
        flags.remove(.CLIENT_DEPRECATE_EOF)
        return flags
    }

    /// Alimenta el comando con una secuencia de paquetes.
    private func feed(_ command: MySQLTextCommand, _ packets: [[UInt8]],
                      capabilities: MySQLProtocol.CapabilityFlags? = nil) throws {
        for bytes in packets {
            var next = packet(bytes)
            _ = try command.handle(packet: &next, capabilities: capabilities ?? modern)
        }
    }

    /// `MySQLError` no conforma `Equatable`, así que se comprueba el caso.
    private func expectProtocolError(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let mysql = error as? MySQLError, case .protocolError = mysql else {
            XCTFail("esperaba protocolError y llegó \(error)", file: file, line: line)
            return
        }
    }

    private func command(byteLimit: Int = 4_000_000, resultLimit: Int = 200) -> MySQLTextCommand {
        MySQLTextCommand(sql: "SELECT 1", statement: 1, line: 1, byteLimit: byteLimit, resultLimit: resultLimit)
    }

    // MARK: - Longitudes

    func testColumnCountUsesTwoByteWidthAndRejectsOutOfRange() throws {
        // 300 columnas: ancho de dos bytes, dentro del límite de 4096.
        let valid = command()
        try feed(valid, [lenenc(300)])

        // 8193 columnas: ancho de tres bytes, fuera del límite.
        let tooMany = command()
        var header = packet(lenenc(8193))
        XCTAssertThrowsError(try tooMany.handle(packet: &header, capabilities: modern)) { error in
            XCTAssertEqual((error as? DatabaseFailure)?.message, "Respuesta MySQL no válida.")
        }

        // Longitud de ocho bytes sin los bytes detrás: no puede leer de más.
        let truncatedLength = command()
        var short = packet([254, 1, 2])
        XCTAssertThrowsError(try truncatedLength.handle(packet: &short, capabilities: modern))
    }

    /// Si alguien tratara el prefijo 253 como dos bytes, este nombre no se decodificaría.
    func testColumnNamesDecodeWithTwoAndThreeByteLengths() throws {
        let corto = String(repeating: "a", count: 300)       // prefijo 252
        let largo = String(repeating: "b", count: 70_000)    // prefijo 253
        let sut = command()
        try feed(sut, [lenenc(2), column(corto), column(largo), row([Array("1".utf8), Array("2".utf8)]),
                       endOfRows()])
        XCTAssertEqual(sut.results.first?.columns, [corto, largo])
    }

    func testRejectsColumnDefinitionCutShort() throws {
        let sut = command()
        try feed(sut, [lenenc(1)])
        var cortado = packet(text("def") + text("db"))
        XCTAssertThrowsError(try sut.handle(packet: &cortado, capabilities: modern)) { error in
            self.expectProtocolError(error)
        }
    }

    // MARK: - Filas

    func testRowKeepsNullEmptyAndBinaryValuesApart() throws {
        let sut = command()
        try feed(sut, [
            lenenc(3),
            column("nulo"),
            column("vacio"),
            column("binario", charset: 63, type: 253),
            row([nil, [], [0x00, 0xFF, 0x10]]),
            endOfRows()
        ])
        let result = try XCTUnwrap(sut.results.first)
        XCTAssertEqual(result.columns, ["nulo", "vacio", "binario"])
        XCTAssertEqual(result.rowCount, 1)
        XCTAssertEqual(result.rows.first?.count, 3)
        XCTAssertNil(result.rows[0][0], "NULL no es la cadena vacía")
        XCTAssertEqual(result.rows[0][1], "")
        XCTAssertEqual(result.rows[0][2], "0x00FF10", "una columna binaria se muestra en hexadecimal")
        XCTAssertFalse(result.truncated)
    }

    func testBinaryIsDetectedAlsoWhenTheBytesAreNotUTF8() throws {
        let sut = command()
        try feed(sut, [lenenc(1), column("texto"), row([[0xC3, 0x28]]), endOfRows()])
        XCTAssertEqual(sut.results.first?.rows.first?.first, "0xC328")
    }

    func testCellOverSixteenKilobytesIsTruncated() throws {
        let sut = command()
        let big = [UInt8](repeating: 0x41, count: 20_000)
        try feed(sut, [lenenc(1), column("grande"), row([big]), endOfRows()])
        let result = try XCTUnwrap(sut.results.first)
        let value = try XCTUnwrap(result.rows.first?.first ?? nil)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(value.hasSuffix("…"))
        XCTAssertEqual(value.count, 16_385, "16.384 caracteres más la marca de corte")
    }

    func testByteLimitStopsStoringButKeepsCounting() throws {
        let sut = command(byteLimit: 200)
        let cell = [UInt8](repeating: 0x42, count: 150)
        try feed(sut, [lenenc(1), column("c"), row([cell]), row([cell]), row([cell]), endOfRows()])
        let result = try XCTUnwrap(sut.results.first)
        XCTAssertEqual(result.rowCount, 3, "las filas se cuentan aunque no se guarden")
        XCTAssertLessThan(result.rows.count, 3)
        XCTAssertTrue(result.truncated)
    }

    // MARK: - Fin de resultado

    func testEOFWithoutDeprecateEOFCarriesWarningsAndStatus() throws {
        let sut = command()
        try feed(sut, [lenenc(1), column("c")], capabilities: legacy)
        try feed(sut, [eofPacket()], capabilities: legacy)   // fin de metadatos
        try feed(sut, [row([Array("x".utf8)])], capabilities: legacy)
        try feed(sut, [eofPacket(status: 0, warnings: 7)], capabilities: legacy)
        let result = try XCTUnwrap(sut.results.first)
        XCTAssertEqual(result.warnings, 7)
        XCTAssertEqual(result.rows.count, 1)
    }

    func testMetadataEndRequiresEOFWhenNotDeprecated() throws {
        let sut = command()
        try feed(sut, [lenenc(1), column("c")], capabilities: legacy)
        var noEOF = packet(row([Array("x".utf8)]))
        XCTAssertThrowsError(try sut.handle(packet: &noEOF, capabilities: legacy)) { error in
            self.expectProtocolError(error)
        }
    }

    func testOKPacketCarriesAffectedRowsAndFinishes() throws {
        let sut = command()
        var ok = packet(okPacket(affected: 42))
        _ = try sut.handle(packet: &ok, capabilities: modern)
        XCTAssertEqual(sut.results.count, 1, "sin más resultados pendientes, el comando termina")
        XCTAssertEqual(sut.results.first?.affectedRows, 42)
    }

    func testMoreResultsBeyondTheLimitFails() throws {
        let sut = command(resultLimit: 1)
        let more = MySQLProtocol.StatusFlags.SERVER_MORE_RESULTS_EXISTS.rawValue
        var ok = packet(okPacket(status: more))
        XCTAssertThrowsError(try sut.handle(packet: &ok, capabilities: modern)) { error in
            XCTAssertEqual((error as? DatabaseFailure)?.message, "Se alcanzó el límite de 200 resultados.")
        }
    }

    func testMoreResultsStartsANewResultWhenThereIsRoom() throws {
        let sut = command(resultLimit: 10)
        let more = MySQLProtocol.StatusFlags.SERVER_MORE_RESULTS_EXISTS.rawValue
        try feed(sut, [okPacket(status: more)])
        XCTAssertEqual(sut.results.count, 1)
        // Y el siguiente paquete vuelve a ser una cabecera de columnas.
        try feed(sut, [lenenc(1), column("c"), row([Array("y".utf8)]), endOfRows()])
        XCTAssertEqual(sut.results.count, 2)
        XCTAssertEqual(sut.results.last?.rows.first?.first, "y")
    }

    // MARK: - Errores del servidor

    func testErrorPacketWithSQLState() throws {
        let sut = command()
        var bytes: [UInt8] = [0xFF, 0x7A, 0x04, 0x23]   // 1146, marcador '#'
        bytes += Array("42S02".utf8) + Array("Table 't' doesn't exist".utf8)
        var error = packet(bytes)
        XCTAssertThrowsError(try sut.handle(packet: &error, capabilities: modern)) { thrown in
            XCTAssertEqual((thrown as? DatabaseFailure)?.message,
                           "MySQL 1146 (42S02): Table 't' doesn't exist")
        }
        XCTAssertTrue(sut.reusableAfterFailure, "un error del servidor no invalida la conexión")
    }

    func testErrorPacketWithoutSQLState() throws {
        let sut = command()
        var bytes: [UInt8] = [0xFF, 0x7A, 0x04]
        bytes += Array("sin estado".utf8)
        var error = packet(bytes)
        XCTAssertThrowsError(try sut.handle(packet: &error, capabilities: modern)) { thrown in
            XCTAssertEqual((thrown as? DatabaseFailure)?.message, "MySQL 1146: sin estado")
        }
    }
}
