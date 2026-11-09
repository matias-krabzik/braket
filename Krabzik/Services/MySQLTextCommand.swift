import Foundation
import MySQLNIO
import NIOCore

private extension ByteBuffer {
    mutating func readSQLLength() -> UInt64? {
        guard let first = readInteger(as: UInt8.self) else { return nil }
        switch first {
        case 0...250: return UInt64(first)
        case 252: return readInteger(endianness: .little, as: UInt16.self).map(UInt64.init)
        case 253:
            guard let data = readBytes(length: 3) else { return nil }
            return UInt64(data[0]) | UInt64(data[1]) << 8 | UInt64(data[2]) << 16
        case 254: return readInteger(endianness: .little, as: UInt64.self)
        default: return nil
        }
    }

    mutating func readSQLSlice() -> ByteBuffer? {
        guard let count = readSQLLength(), count <= readableBytes else { return nil }
        return readSlice(length: Int(count))
    }

    mutating func readSQLString() -> String? {
        guard var value = readSQLSlice() else { return nil }
        return value.readString(length: value.readableBytes)
    }
}

/// Text protocol keeps decimal precision, zero dates and SQL NULL intact. All
/// mutable members of a command are confined to the connection's event loop.
final class MySQLTextCommand: MySQLCommand, @unchecked Sendable {
    private enum Phase { case header, columns(Int), metadataEnd, rows }
    private var phase = Phase.header
    private var columnNames: [String] = []
    private var binaryColumns: [Bool] = []
    private var current: SQLResult
    private(set) var results: [SQLResult] = []
    private(set) var status: MySQLProtocol.StatusFlags = []
    private(set) var reusableAfterFailure = false
    private let sql: String
    private let started = Date()
    private var storedBytes = 0
    private let byteLimit: Int
    private let resultLimit: Int

    init(sql: String, statement: Int, line: Int, byteLimit: Int = 4_000_000, resultLimit: Int = 200) {
        self.sql = sql
        self.byteLimit = max(0, byteLimit)
        self.resultLimit = resultLimit
        current = SQLResult(statement: statement, line: line)
    }

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        .init(response: [try .encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)])
    }

    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isError {
            reusableAfterFailure = true
            packet.payload.moveReaderIndex(forwardBy: 1)
            let code = packet.payload.readInteger(endianness: .little, as: UInt16.self) ?? 0
            var state = ""
            if packet.payload.getInteger(at: packet.payload.readerIndex, as: UInt8.self) == 35 {
                packet.payload.moveReaderIndex(forwardBy: 1)
                state = packet.payload.readString(length: 5) ?? ""
            }
            let message = packet.payload.readString(length: packet.payload.readableBytes) ?? "Error del servidor"
            throw DatabaseFailure("MySQL \(code)\(state.isEmpty ? "" : " (\(state))"): \(message)")
        }
        switch phase {
        case .header:
            if packet.isOK { return try finish(&packet, capabilities: capabilities) }
            guard let count = packet.payload.readSQLLength(), count > 0, count <= 4096 else {
                throw DatabaseFailure("Respuesta MySQL no válida.")
            }
            columnNames = []; binaryColumns = []
            phase = .columns(Int(count))
        case .columns(let count):
            // Read the two-byte collation ID directly (modern IDs may exceed 255).
            for _ in 0..<4 { guard packet.payload.readSQLSlice() != nil else { throw MySQLError.protocolError } }
            guard let name = packet.payload.readSQLString(),
                  packet.payload.readSQLSlice() != nil,
                  packet.payload.readSQLLength() != nil,
                  let charset = packet.payload.readInteger(endianness: .little, as: UInt16.self),
                  packet.payload.readInteger(endianness: .little, as: UInt32.self) != nil,
                  let type = packet.payload.readInteger(as: UInt8.self) else { throw MySQLError.protocolError }
            columnNames.append(name)
            binaryColumns.append(charset == 63 && [UInt8(249), 250, 251, 252, 253, 254, 255, 16].contains(type))
            if columnNames.count == count {
                current.columns = columnNames
                phase = capabilities.contains(.CLIENT_DEPRECATE_EOF) ? .rows : .metadataEnd
            }
        case .metadataEnd:
            guard packet.isEOF else { throw MySQLError.protocolError }
            phase = .rows
        case .rows:
            // A text row can begin with 0x00 (empty string) or with 0xFE for a
            // very large field. EOF/OK has 0xFE and a payload below 16 MiB.
            if packet.isEOF && packet.payload.readableBytes < 0xFF_FFFF {
                return try finish(&packet, capabilities: capabilities)
            }
            let row = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: columnNames.count)
            current.rowCount += 1
            guard current.rows.count < 1000, storedBytes < byteLimit else { current.truncated = true; return .init() }
            var values: [String?] = []
            for (index, buffer) in row.values.enumerated() {
                storedBytes += 16 // Include storage for NULL and empty cells.
                guard storedBytes <= byteLimit else { current.truncated = true; return .init() }
                guard let buffer else { values.append(nil); continue }
                let bytes = buffer.readableBytesView.prefix(16_384)
                let truncated = buffer.readableBytes > bytes.count
                let value: String
                if binaryColumns[index] || String(bytes: bytes, encoding: .utf8) == nil {
                    value = "0x" + bytes.map { String(format: "%02X", $0) }.joined()
                } else { value = String(decoding: bytes, as: UTF8.self) }
                storedBytes += value.utf8.count + (truncated ? 3 : 0)
                current.truncated = current.truncated || truncated
                values.append(value + (truncated ? "…" : ""))
            }
            if storedBytes <= byteLimit { current.rows.append(values) }
            else { current.truncated = true }
        }
        return .init()
    }

    private func finish(_ packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isEOF && !capabilities.contains(.CLIENT_DEPRECATE_EOF) {
            packet.payload.moveReaderIndex(forwardBy: 1)
            current.warnings = Int(packet.payload.readInteger(endianness: .little, as: UInt16.self) ?? 0)
            status = .init(rawValue: packet.payload.readInteger(endianness: .little, as: UInt16.self) ?? 0)
        } else {
            // Decode negotiated flags, not all capabilities advertised by the server.
            let ok = try MySQLProtocol.OK_Packet.decode(from: &packet, capabilities: capabilities.intersection(.clientDefault))
            current.affectedRows = ok.affectedRows
            current.warnings = Int(ok.warningsCount ?? 0)
            status = ok.statusFlags
        }
        current.elapsed = Date().timeIntervalSince(started)
        results.append(current)
        if status.contains(.SERVER_MORE_RESULTS_EXISTS) {
            guard results.count < resultLimit else { throw DatabaseFailure("Se alcanzó el límite de 200 resultados.") }
            current = SQLResult(statement: current.statement, line: current.line)
            phase = .header
            return .init()
        }
        return .init(done: true)
    }
}
