@testable import Krabzik
import NIOCore
import NIOPosix
import XCTest

@MainActor
final class SQLHistoryIntegrationTests: XCTestCase {
    func testActualClientRecordsStatementsErrorsMetadataAndTimeouts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("output-wire-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLHistoryStore(url: root.appendingPathComponent("output.sqlite"))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(HistoryMySQLHandler())
        }.bind(host: "127.0.0.1", port: 0).get()
        let client = MySQLClient(readPassword: { _ in "" }, historyProvider: { store })
        do {
            var config = DatabaseConnection(name: "History wire test")
            config.port = try XCTUnwrap(server.localAddress?.port)
            config.database = "demo"
            config.tls = .disabled
            _ = try await client.execute("SELECT 1; UPDATE test SET a = 2", startingLine: 1, configuration: config,
                                         password: "", operation: UUID()) { _ in }
            do {
                _ = try await client.execute("BAD QUERY; SELECT 'never sent'", startingLine: 1, configuration: config,
                                             password: "", operation: UUID()) { _ in }
                XCTFail("The server rejects BAD QUERY")
            } catch {}
            _ = try await client.metadataQuery("SHOW DATABASES", configuration: config, password: "")
            do {
                _ = try await client.execute("SELECT SLEEP(20)", startingLine: 1, configuration: config,
                                             password: "", operation: UUID(), timeoutSeconds: 1) { _ in }
                XCTFail("The server never responds to SLEEP")
            } catch {}
            let entries = try await store.page()
            XCTAssertEqual(entries.filter { $0.sql == "SELECT 1" }.count, 1)
            XCTAssertEqual(entries.first { $0.sql == "SELECT 1" }?.rows, 1)
            XCTAssertEqual(entries.first { $0.sql.hasPrefix("UPDATE") }?.affected, "1")
            XCTAssertEqual(entries.first { $0.sql == "BAD QUERY" }?.status, "error")
            XCTAssertFalse(entries.contains { $0.sql.contains("never sent") })
            XCTAssertEqual(entries.first { $0.sql == "SHOW DATABASES" }?.source, "Explorador")
            XCTAssertEqual(entries.first { $0.sql == "SELECT SLEEP(20)" }?.status, "timeout")
            XCTAssertFalse(entries.contains { $0.status == "running" })
            await client.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
            await store.close()
        } catch {
            await client.shutdown()
            try? await server.close().get()
            try? await group.shutdownGracefully()
            await store.close()
            throw error
        }
    }
}

/// Minimal real MySQL wire server, independent of Docker and the user's databases.
private final class HistoryMySQLHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var input = ByteBuffer()
    private var authenticated = false

    func channelActive(context: ChannelHandlerContext) {
        let capabilities: UInt32 = 0x0008_8201
        var payload = context.channel.allocator.buffer(capacity: 100)
        payload.writeInteger(UInt8(10))
        payload.writeNullTerminatedString("8.0.0-output-test")
        payload.writeInteger(UInt32(1), endianness: .little)
        payload.writeString("12345678")
        payload.writeInteger(UInt8(0))
        payload.writeInteger(UInt16(truncatingIfNeeded: capabilities), endianness: .little)
        payload.writeInteger(UInt8(45))
        payload.writeInteger(UInt16(2), endianness: .little)
        payload.writeInteger(UInt16(capabilities >> 16), endianness: .little)
        payload.writeInteger(UInt8(21))
        payload.writeRepeatingByte(0, count: 10)
        payload.writeNullTerminatedString("abcdefghijkl")
        payload.writeNullTerminatedString("mysql_native_password")
        send(Array(payload.readableBytesView), sequence: 0, context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        input.writeBuffer(&bytes)
        while input.readableBytes >= 4 {
            guard let header: UInt32 = input.getInteger(at: input.readerIndex, endianness: .little) else { return }
            let length = Int(header & 0x00FF_FFFF)
            guard input.readableBytes >= length + 4 else { return }
            input.moveReaderIndex(forwardBy: 4)
            guard let payload = input.readBytes(length: length) else { return }
            if !authenticated {
                authenticated = true
                send([0, 0, 0, 2, 0, 0, 0], sequence: 2, context: context)
                continue
            }
            guard payload.first == 3 else { context.close(promise: nil)
            return }
            let sql = String(decoding: payload.dropFirst(), as: UTF8.self)
            if sql.contains("SLEEP") { continue }
            if sql == "BAD QUERY" {
                send([0xFF, 0x28, 0x04] + Array("#42000Syntax error".utf8), sequence: 1, context: context)
            } else if sql.hasPrefix("SELECT") || sql.hasPrefix("SHOW") {
                result(sql.contains("CONNECTION_ID") ? ["1", "demo"] : ["1"], context: context)
            } else {
                send([0, 1, 0, 2, 0, 0, 0], sequence: 1, context: context)
            }
        }
        input.discardReadBytes()
    }

    private func result(_ values: [String], context: ChannelHandlerContext) {
        send([UInt8(values.count)], sequence: 1, context: context)
        for (index, _) in values.enumerated() {
            let column = ["def", "demo", "", "", "value\(index)", ""].flatMap(text)
                + [12, 45, 0, 0, 0, 1, 0, 253, 0, 0, 0, 0, 0]
            send(column, sequence: UInt8(index + 2), context: context)
        }
        send([0xFE, 0, 0, 2, 0], sequence: UInt8(values.count + 2), context: context)
        send(values.flatMap(text), sequence: UInt8(values.count + 3), context: context)
        send([0xFE, 0, 0, 2, 0], sequence: UInt8(values.count + 4), context: context)
    }

    private func text(_ value: String) -> [UInt8] { [UInt8(value.utf8.count)] + Array(value.utf8) }

    private func send(_ bytes: [UInt8], sequence: UInt8, context: ChannelHandlerContext) {
        var packet = context.channel.allocator.buffer(capacity: bytes.count + 4)
        packet.writeInteger(UInt32(bytes.count) | UInt32(sequence) << 24, endianness: .little)
        packet.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(packet), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
