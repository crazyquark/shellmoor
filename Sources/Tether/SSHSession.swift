import Foundation
import UIKit
import Observation
import NIOSSH
import SwiftTerm

struct HostKeyPrompt: Identifiable {
    let id = UUID()
    let keyLine: String
    let fingerprint: String
    let previousFingerprint: String?
}

/// A live SSH session with its terminal. Sessions outlive the screen showing them,
/// so you can leave a terminal and come back to it with its scrollback intact.
@Observable
final class SSHSession: NSObject, Identifiable, TerminalViewDelegate {
    enum State: Equatable {
        case connecting, authenticating, connected, disconnected(String?)
        var label: String {
            switch self {
            case .connecting: return "Connecting…"
            case .authenticating: return "Authenticating…"
            case .connected: return "Connected"
            case .disconnected(let e): return e ?? "Disconnected"
            }
        }
        var isLive: Bool { self == .connecting || self == .authenticating || self == .connected }
    }

    let id = UUID()
    private(set) var host: Host
    var state: State = .disconnected(nil)
    var title: String = ""
    var hostKeyPrompt: HostKeyPrompt?
    var passwordPrompt = false

    @ObservationIgnored let terminalView: TerminalView
    @ObservationIgnored private unowned let store: Store
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var cols = 80
    @ObservationIgnored private var rows = 24
    @ObservationIgnored private var hostKeyReply: ((Bool) -> Void)?
    @ObservationIgnored private var pendingHostKey: String?
    @ObservationIgnored private var passwordReply: ((String?) -> Void)?

    init(host: Host, store: Store) {
        self.host = host
        self.store = store
        self.terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        super.init()
        terminalView.terminalDelegate = self
        applyAppearance()
        title = host.displayName
    }

    // MARK: Appearance

    func applyAppearance() {
        if let fresh = store.host(host.id) { host = fresh }
        let theme = store.theme(for: host)
        terminalView.font = UIFont.monospacedSystemFont(ofSize: CGFloat(store.settings.fontSize), weight: .regular)
        terminalView.installColors(theme.terminalColors)
        terminalView.nativeForegroundColor = theme.uiForeground
        terminalView.nativeBackgroundColor = theme.uiBackground
        terminalView.backgroundColor = theme.uiBackground
        terminalView.caretColor = theme.uiCursor
        terminalView.optionAsMetaKey = store.settings.optionAsMeta
        terminalView.keyboardAppearance = theme.isDark ? .dark : .light
    }

    // MARK: Lifecycle

    func connect() {
        guard !state.isLive else { return }
        Diagnostics.log("connect \(host.hostname):\(host.port) auth=\(host.auth.rawValue)")
        state = .connecting
        terminalView.feed(text: "\u{1b}[2mConnecting to \(host.address)…\u{1b}[0m\r\n")

        var key: NIOSSHPrivateKey?
        if host.auth == .key {
            var problem: String?
            if let rec = store.key(host.keyID) {
                do { key = try KeyManager.load(rec) } catch { problem = error.localizedDescription }
            } else { problem = "No key selected for this server." }
            if let problem { terminalView.feed(text: "\u{1b}[33m\(problem) Falling back to password.\u{1b}[0m\r\n") }
        }

        let conn = SSHConnection(config: .init(
            hostname: host.hostname, port: host.port,
            username: host.username.isEmpty ? "root" : host.username,
            privateKey: key, storedPassword: Keychain.string(account: host.passwordAccount),
            cols: cols, rows: rows))
        conn.verifyHostKey = { [weak self] line, reply in self?.verifyHostKey(line, reply: reply) ?? reply(false) }
        conn.requestPassword = { [weak self] reply in
            guard let self else { return reply(nil) }
            self.passwordReply = reply
            self.passwordPrompt = true
        }
        conn.onEvent = { [weak self, weak conn] event in
            guard let self, let conn, conn === self.connection else { return }
            self.handle(event)
        }
        connection = conn
        conn.connect()
    }

    private func handle(_ event: SSHConnection.Event) {
        if case .data = event {} else { Diagnostics.log("event \(event)") }
        switch event {
        case .connected:
            state = .authenticating
        case .shellReady:
            state = .connected
            store.touch(hostID: host.id)
            connection?.resize(cols: cols, rows: rows)
            let cmd = host.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty { send(text: cmd + "\r") }
        case .data(let bytes):
            terminalView.feed(byteArray: bytes[...])
        case .closed(let error):
            dismissPrompts()
            connection = nil
            state = .disconnected(error)
            terminalView.feed(text: "\r\n\u{1b}[2m[\(error ?? "Connection closed")]\u{1b}[0m\r\n")
        }
    }

    func disconnect() {
        dismissPrompts()
        connection?.close()
    }

    func reconnect() {
        terminalView.feed(text: "\r\n")
        connect()
    }

    private func dismissPrompts() {
        if hostKeyReply != nil { resolveHostKey(trust: false) }
        if passwordReply != nil { resolvePassword(nil) }
    }

    // MARK: I/O

    func send(text: String) { send(bytes: Array(text.utf8)) }
    func send(bytes: [UInt8]) { connection?.send(bytes) }

    // MARK: Prompts

    private func verifyHostKey(_ line: String, reply: @escaping (Bool) -> Void) {
        Diagnostics.log("verify host key \(KeyManager.fingerprint(openSSHLine: line))")
        let known = store.knownHosts[knownHostID]
        if known == line { return reply(true) }
        hostKeyReply = reply
        pendingHostKey = line
        hostKeyPrompt = HostKeyPrompt(keyLine: line, fingerprint: KeyManager.fingerprint(openSSHLine: line),
                                      previousFingerprint: known.map { KeyManager.fingerprint(openSSHLine: $0) })
    }

    private var knownHostID: String { "\(host.hostname):\(host.port)" }

    func resolveHostKey(trust: Bool) {
        guard let reply = hostKeyReply else { return }
        hostKeyReply = nil
        hostKeyPrompt = nil
        if trust, let line = pendingHostKey { store.knownHosts[knownHostID] = line }
        reply(trust)
    }

    func resolvePassword(_ password: String?, remember: Bool = false) {
        guard let reply = passwordReply else { return }
        passwordReply = nil
        passwordPrompt = false
        if let password, remember { Keychain.setString(password, account: host.passwordAccount) }
        reply(password)
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        cols = newCols; rows = newRows
        connection?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        self.title = title.isEmpty ? host.displayName : title
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) { send(bytes: Array(data)) }

    func bell(source: TerminalView) {
        if store.settings.bellHaptic { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func clipboardRead(source: TerminalView) -> Data? { UIPasteboard.general.string.map { Data($0.utf8) } }
}
