@testable import Krabzik
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import XCTest

final class MySQLDiagnosticsTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("braket-mysql-log-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLogSurvivesReopeningAndExportsTLSCauseWithoutConnectionData() async throws {
        let directory = try directory(), attempt = UUID()
        let log = MySQLDiagnostics(directory: directory)
        var config = DatabaseConnection()
        config.name = "private-project"
        config.host = "private-host.example"
        config.username = "private-user"
        config.database = "private-db"
        await log.record(.started, attempt: attempt, configuration: config)
        await log.record(.failed, attempt: attempt, configuration: config, elapsedMilliseconds: 123,
                         error: NIOSSLError.handshakeFailed(.sslError([.eofDuringHandshake])))
        let reopened = MySQLDiagnostics(directory: directory)
        let exported = directory.appendingPathComponent("export.txt")
        try await reopened.export(to: exported)
        let text = try String(contentsOf: exported, encoding: .utf8)
        for expected in [attempt.uuidString, "handshakeFailed", "EOF during handshake", "123", "appBuild", "macOS"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        for secret in [config.name, config.host, config.username, config.database] { XCTAssertFalse(text.contains(secret), secret) }
        for name in ["mysql.jsonl", "export.txt"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testUnknownAndServerErrorsDoNotPersistFreeText() throws {
        let secret = "SELECT password FROM private_database; secret-password"
        for error in [NSError(domain: "test", code: 42, userInfo: [NSLocalizedDescriptionKey: secret]) as Error,
                      MySQLError.invalidSyntax(secret), DatabaseFailure(secret)] {
            let fields = MySQLDiagnostics.errorFields(error)
            XCTAssertFalse(String(describing: fields).contains(secret))
            XCTAssertNotNil(fields["errorType"])
        }
    }

    func testConcurrentRecordsRotateAndRemainValidJSON() async throws {
        let directory = try directory(), config = DatabaseConnection()
        let log = MySQLDiagnostics(directory: directory, maximumBytes: 2048)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 30 {
                group.addTask { await log.record(.started, attempt: UUID(), configuration: config) }
            }
        }
        let latest = UUID()
        await log.record(.ready, attempt: latest, configuration: config)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["mysql.jsonl", "mysql.previous.jsonl"])
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 2048)
            for line in data.split(separator: 0x0A) {
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line)))
            }
        }
        let snapshot = try await log.snapshot()
        XCTAssertTrue(String(decoding: snapshot, as: UTF8.self).contains(latest.uuidString))
    }

    func testWriteFailureIsReportedAtExportInsteadOfSilentlyExportingOldLogs() async throws {
        let directory = try directory().appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: directory)
        let log = MySQLDiagnostics(directory: directory)
        await log.record(.started, attempt: UUID(), configuration: DatabaseConnection())
        do {
            _ = try await log.snapshot()
            XCTFail("Debe informar que no pudo guardar el diagnóstico")
        } catch {
            XCTAssertTrue(AppError.describe(error).contains("No se pudo guardar el diagnóstico MySQL"))
        }
    }

    func testRealMySQLTLSFailureRecordsUnderlyingErrorAndStages() async throws {
        let directory = try directory(), group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let log = MySQLDiagnostics(directory: directory), client = MySQLClient(diagnostics: log)
        let address = try SocketAddress.makeAddressResolvingHost("localhost", port: 0)
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(BrokenMySQLTLSHandler())
        }.bind(to: address).get()
        do {
            var config = DatabaseConnection()
            config.host = "localhost"
            config.port = try XCTUnwrap(server.localAddress?.port)
            do {
                try await client.test(config, password: "must-not-appear-in-logs")
                XCTFail("El servidor de prueba no puede completar TLS")
            } catch {
                guard let tls = error as? NIOSSLError, case .handshakeFailed = tls else {
                    XCTFail("Se esperaba un fallo TLS real, llegó \(error)")
                    throw error
                }
                XCTAssertFalse(AppError.describe(error).contains("NIOSSL.NIOSSLError"))
            }
            let data = try await log.snapshot(), text = String(decoding: data, as: UTF8.self)
            for expected in ["connection.started", "dns.resolved", "tcp_tls_auth.started", "connection.failed", "handshakeFailed"] {
                XCTAssertTrue(text.contains(expected), expected)
            }
            XCTAssertTrue(text.contains("tlsDetail"))
            XCTAssertFalse(text.contains("must-not-appear-in-logs"))
            XCTAssertFalse(text.contains("connection.authenticated"))
            await client.shutdown()
            try await server.close().get()
            try await group.shutdownGracefully()
        } catch {
            await client.shutdown()
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func testPreferredFallsBackOnlyWhenServerOmitsTLS() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let log = MySQLDiagnostics(directory: try directory())
        let client = MySQLClient(diagnostics: log)
        let sawPlaintextHandshake = expectation(description: "MySQL respondió sin TLS en modo If available")
        let address = try SocketAddress.makeAddressResolvingHost("localhost", port: 0)
        let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(BrokenMySQLTLSHandler(advertisesTLS: false) { sawPlaintextHandshake.fulfill() })
        }.bind(to: address).get()
        do {
            var config = DatabaseConnection()
            config.host = "localhost"
            config.port = try XCTUnwrap(server.localAddress?.port)
            config.tls = .preferred
            do {
                try await client.test(config, password: "test")
                XCTFail("El servidor simulado no acepta la autenticación")
            } catch let error as MySQLError {
                if case .unsupportedServer = error { XCTFail("If available no debe exigir TLS") }
            } catch { /* El servidor simulado rechaza la autenticación. */ }
            await fulfillment(of: [sawPlaintextHandshake], timeout: 1)
            try await server.close().get()
            let requiredServer = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                channel.pipeline.addHandler(BrokenMySQLTLSHandler(advertisesTLS: false))
            }.bind(to: address).get()
            config.tls = .required
            config.port = try XCTUnwrap(requiredServer.localAddress?.port)
            do {
                try await client.test(config, password: "test")
                XCTFail("Require debe rechazar un servidor sin TLS")
            } catch let error as MySQLError {
                guard case .unsupportedServer = error else {
                    XCTFail("Require debe informar que falta TLS: \(error)")
                    throw error
                }
            }
            await client.shutdown()
            try await requiredServer.close().get()
            try await group.shutdownGracefully()
        } catch {
            await client.shutdown()
            try? await server.close().get()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

/// Anuncia MySQL con TLS y responde con texto plano al SSLRequest, simulando un
/// servidor/proxy mal configurado. Ejercita el handshake real sin una base externa.
private final class BrokenMySQLTLSHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var replied = false
    private let advertisesTLS: Bool
    private let onRead: @Sendable () -> Void

    init(advertisesTLS: Bool = true, onRead: @escaping @Sendable () -> Void = {}) {
        self.advertisesTLS = advertisesTLS
        self.onRead = onRead
    }

    func channelActive(context: ChannelHandlerContext) {
        let capabilities: UInt32 = advertisesTLS ? 0x0008_8A01 : 0x0008_8201
        var payload = context.channel.allocator.buffer(capacity: 100)
        payload.writeInteger(UInt8(10))
        payload.writeNullTerminatedString("8.0.0-test")
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
        var packet = context.channel.allocator.buffer(capacity: 104)
        packet.writeInteger(UInt32(payload.readableBytes), endianness: .little)
        packet.writeBuffer(&payload)
        context.writeAndFlush(wrapOutboundOut(packet), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !replied else { return }
        replied = true
        onRead()
        var reply = context.channel.allocator.buffer(capacity: 40)
        if advertisesTLS {
            reply.writeString("HTTP/1.1 400 Bad Request\r\n\r\n")
        } else {
            let message = "Acceso de prueba rechazado"
            reply.writeInteger(UInt32(9 + message.utf8.count), endianness: .little)
            reply.moveWriterIndex(to: 3)
            reply.writeInteger(UInt8(2))
            reply.writeInteger(UInt8(0xFF))
            reply.writeInteger(UInt16(1045), endianness: .little)
            reply.writeString("#28000")
            reply.writeString(message)
        }
        context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
