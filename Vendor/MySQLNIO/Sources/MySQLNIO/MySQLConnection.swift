import NIOCore
import Logging
import NIOSSL
import NIOPosix

public final class MySQLConnection: MySQLDatabase, Sendable {
    public static func connect(
        to socketAddress: SocketAddress,
        username: String,
        database: String,
        password: String? = nil,
        tlsConfiguration: TLSConfiguration? = .makeClientConfiguration(),
        tlsRequired: Bool = true,
        serverHostname: String? = nil,
        logger: Logger = .init(label: "codes.vapor.mysql"),
        connectTimeout: TimeAmount = .seconds(10),
        on eventLoop: any EventLoop
    ) -> EventLoopFuture<MySQLConnection> {
        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(connectTimeout)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        
        logger.debug("Opening new connection to \(socketAddress)")
        
        return bootstrap.connect(to: socketAddress).flatMap { channel in
            let sequence = MySQLPacketSequence()
            let done = channel.eventLoop.makePromise(of: Void.self)
            // Krabzik: bound authentication as well as TCP connection setup.
            let completed = NIOLoopBoundBox(false, eventLoop: channel.eventLoop)
            let deadline = channel.eventLoop.scheduleTask(in: connectTimeout) {
                if !completed.value { done.fail(ChannelError.connectTimeout(connectTimeout)) }
            }
            done.futureResult.whenComplete { _ in
                completed.value = true
                deadline.cancel()
            }
            done.futureResult.whenFailure { _ in channel.close(mode: .all, promise: nil) }
            channel.closeFuture.whenComplete { _ in
                if !completed.value { done.fail(MySQLError.closed) }
            }
            do {
                try channel.pipeline.syncOperations.addHandlers([
                    ByteToMessageHandler(MySQLPacketDecoder(
                        sequence: sequence,
                        logger: logger
                    )),
                    MessageToByteHandler(MySQLPacketEncoder(
                        sequence: sequence,
                        logger: logger
                    )),
                    MySQLConnectionHandler(logger: logger, state: .handshake(.init(
                        username: username,
                        database: database,
                        password: password,
                        tlsConfiguration: tlsConfiguration,
                        tlsRequired: tlsRequired,
                        serverHostname: serverHostname,
                        done: done
                    )), sequence: sequence),
                    ErrorHandler()
                ], position: .last)
            } catch {
                done.fail(error)
            }

            return done.futureResult.map { MySQLConnection(channel: channel, logger: logger) }
        }
    }
    
    public let channel: any Channel
    
    public var eventLoop: any EventLoop {
        self.channel.eventLoop
    }
    
    public let logger: Logger
    
    public var isClosed: Bool {
        !self.channel.isActive
    }
    
    internal init(channel: any Channel, logger: Logger) {
        self.channel = channel
        self.logger = logger
    }
    
    public func close() -> EventLoopFuture<Void> {
        guard self.channel.isActive else {
            return self.channel.eventLoop.makeSucceededFuture(())
        }
        return self.channel.close(mode: .all)
    }
    
    public func send(_ command: any MySQLCommand, logger: Logger) -> EventLoopFuture<Void> {
        guard self.channel.isActive else {
            return self.channel.eventLoop.makeFailedFuture(MySQLError.closed)
        }

        let promise = self.eventLoop.makePromise(of: Void.self)
        
        let c = MySQLCommandContext(
            handler: command,
            promise: promise
        )
        return self.channel.write(c)
            .flatMap { promise.futureResult }
    }
    
    public func withConnection<T>(_ closure: @escaping (MySQLConnection) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        closure(self)
    }
    
    deinit {
        assert(!self.channel.isActive, "MySQLConnection not closed before deinit.")
    }
}

final class ErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Never
    
    init() { }
    
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        assertionFailure("uncaught error: \(error)")
    }
}
