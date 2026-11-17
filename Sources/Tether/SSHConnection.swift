import Foundation
import NIOCore
import NIOPosix
import NIOSSH

enum SessionError: LocalizedError {
    case authFailed, hostKeyRejected, cancelled, noShell
    var errorDescription: String? {
        switch self {
        case .authFailed: return "Authentication failed."
        case .hostKeyRejected: return "Host key was not trusted."
        case .cancelled: return "Cancelled."
        case .noShell: return "The server refused to open a shell."
        }
    }
}

/// UI-agnostic SSH transport: TCP connect, key exchange, auth, and an interactive PTY shell.
/// All callbacks are invoked on `callbackQueue` (the main queue in the app).
final class SSHConnection: @unchecked Sendable {
    struct Config {
        var hostname: String
        var port: Int
        var username: String
        var privateKey: NIOSSHPrivateKey?
        var storedPassword: String?
        var term = "xterm-256color"
        var cols = 80
        var rows = 24
    }

    enum Event {
        case connected            // TCP up, SSH handshake in progress
        case shellReady
        case data([UInt8])
        case closed(String?)      // nil = clean close
    }

    /// Ask the user whether to trust `key` (OpenSSH line). Call `completion(true)` to accept.
    var verifyHostKey: (_ openSSHLine: String, _ completion: @escaping (Bool) -> Void) -> Void = { _, c in c(false) }
    /// Ask the user for a password. Call `completion(nil)` to cancel.
    var requestPassword: (_ completion: @escaping (String?) -> Void) -> Void = { c in c(nil) }
    var onEvent: (Event) -> Void = { _ in }

    static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private let config: Config
    private let callbackQueue: DispatchQueue
    private var root: Channel?
    private var shell: Channel?
    private var cols: Int
    private var rows: Int
    private var closed = false
    private var userClosing = false
    private let lock = NSLock()

    init(config: Config, callbackQueue: DispatchQueue = .main) {
        self.config = config
        self.callbackQueue = callbackQueue
        self.cols = config.cols
        self.rows = config.rows
    }

    func connect() {
        let auth = AuthDelegate(connection: self, username: config.username,
                                key: config.privateKey, storedPassword: config.storedPassword)
        let serverAuth = HostKeyDelegate(connection: self)

        let bootstrap = ClientBootstrap(group: Self.group)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_KEEPALIVE), value: 1)
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: serverAuth)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    try channel.pipeline.syncOperations.addHandler(RootErrorHandler(connection: self))
                }
            }

        bootstrap.connect(host: config.hostname, port: config.port).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(Self.describe(error))
            case .success(let channel):
                self.lock.withLock { self.root = channel }
                self.emit(.connected)
                channel.closeFuture.whenComplete { _ in self.finish(nil) }
                self.openShell(on: channel)
            }
        }
    }

    private func openShell(on channel: Channel) {
        channel.eventLoop.execute { [weak self] in
            guard let self else { return }
            do {
                let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let promise = channel.eventLoop.makePromise(of: Channel.self)
                let (cols, rows) = self.lock.withLock { (self.cols, self.rows) }
                ssh.createChannel(promise) { child, type in
                    guard type == .session else { return child.eventLoop.makeFailedFuture(SessionError.noShell) }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            ShellHandler(connection: self, term: self.config.term, cols: cols, rows: rows))
                    }
                }
                promise.futureResult.whenComplete { result in
                    switch result {
                    case .success(let shell):
                        self.lock.withLock { self.shell = shell }
                        self.emit(.shellReady)
                    case .failure(let error):
                        self.finish(Self.describe(error))
                        channel.close(promise: nil)
                    }
                }
            } catch {
                self.finish(Self.describe(error))
            }
        }
    }

    func send(_ bytes: [UInt8]) {
        guard let shell = lock.withLock({ shell }) else { return }
        var buf = shell.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        shell.writeAndFlush(buf, promise: nil)
    }

    func resize(cols: Int, rows: Int) {
        let shell: Channel? = lock.withLock {
            self.cols = cols; self.rows = rows
            return self.shell
        }
        shell?.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: cols, terminalRowHeight: rows,
                                                       terminalPixelWidth: 0, terminalPixelHeight: 0),
            promise: nil)
    }

    func close() {
        let (shell, root) = lock.withLock { () -> (Channel?, Channel?) in
            userClosing = true
            return (self.shell, self.root)
        }
        shell?.close(promise: nil)
        root?.close(promise: nil)
        if root == nil { finish(nil) }
    }

    // MARK: Internals

    fileprivate func emit(_ event: Event) {
        callbackQueue.async { self.onEvent(event) }
    }

    fileprivate func finish(_ error: String?) {
        let (first, byUser): (Bool, Bool) = lock.withLock {
            defer { closed = true; shell = nil; root = nil }
            return (!closed, userClosing)
        }
        // Errors raised while we tear the connection down ourselves aren't failures.
        if first { emit(.closed(byUser ? nil : error)) }
    }

    fileprivate func received(_ bytes: [UInt8]) { emit(.data(bytes)) }

    fileprivate func askHostKey(_ key: NIOSSHPublicKey, promise: EventLoopPromise<Void>) {
        let line = String(openSSHPublicKey: key)
        callbackQueue.async {
            self.verifyHostKey(line) { ok in
                if ok { promise.succeed(()) } else { promise.fail(SessionError.hostKeyRejected) }
            }
        }
    }

    fileprivate func askPassword(promise: EventLoopPromise<String?>) {
        callbackQueue.async { self.requestPassword { promise.succeed($0) } }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if let e = error as? NIOConnectionError {
            if let first = e.connectionErrors.first { return "Couldn't reach the server: \(first.error)" }
            if let dns = e.dnsAError ?? e.dnsAAAAError { return "Couldn't resolve host: \(dns)" }
            return "Couldn't reach the server."
        }
        if error is ChannelError { return "Connection failed (\(error))." }
        if let ssh = error as? NIOSSHError { return "SSH error: \(ssh)" }
        return String(describing: error)
    }
}

// MARK: - NIO handlers

private final class HostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    weak var connection: SSHConnection?
    init(connection: SSHConnection) { self.connection = connection }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let connection else { validationCompletePromise.fail(SessionError.cancelled); return }
        connection.askHostKey(hostKey, promise: validationCompletePromise)
    }
}

private final class AuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    weak var connection: SSHConnection?
    let username: String
    let key: NIOSSHPrivateKey?
    let storedPassword: String?
    var triedKey = false
    var passwordAttempts = 0

    init(connection: SSHConnection, username: String, key: NIOSSHPrivateKey?, storedPassword: String?) {
        self.connection = connection; self.username = username; self.key = key; self.storedPassword = storedPassword
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        if let key, !triedKey, availableMethods.contains(.publicKey) {
            triedKey = true
            nextChallengePromise.succeed(.init(username: username, serviceName: "",
                                               offer: .privateKey(.init(privateKey: key))))
            return
        }
        guard availableMethods.contains(.password), passwordAttempts < 3, let connection else {
            nextChallengePromise.fail(SessionError.authFailed)
            return
        }
        passwordAttempts += 1
        if passwordAttempts == 1, let storedPassword, !storedPassword.isEmpty {
            nextChallengePromise.succeed(.init(username: username, serviceName: "",
                                               offer: .password(.init(password: storedPassword))))
            return
        }
        let pw = nextChallengePromise.futureResult.eventLoop.makePromise(of: String?.self)
        connection.askPassword(promise: pw)
        pw.futureResult.whenComplete { [username] result in
            if case .success(let p?) = result {
                nextChallengePromise.succeed(.init(username: username, serviceName: "", offer: .password(.init(password: p))))
            } else {
                nextChallengePromise.fail(SessionError.cancelled)
            }
        }
    }
}

private final class RootErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    weak var connection: SSHConnection?
    init(connection: SSHConnection?) { self.connection = connection }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        connection?.finish(SSHConnection.describe(error))
        context.close(promise: nil)
    }
}

private final class ShellHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    weak var connection: SSHConnection?
    let term: String
    let cols: Int, rows: Int

    init(connection: SSHConnection?, term: String, cols: Int, rows: Int) {
        self.connection = connection; self.term = term; self.cols = cols; self.rows = rows
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false, term: term,
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"), promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: false), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let msg = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = msg.data else { return }
        connection?.received(Array(buf.readableBytesView))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, case .inputClosed = e {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // The shell ended (e.g. `exit`): tear down the whole connection.
        context.channel.parent?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        connection?.finish(SSHConnection.describe(error))
        context.close(promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buf))), promise: promise)
    }
}
