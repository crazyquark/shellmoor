import Foundation
import Observation

@Observable
final class SessionManager {
    var sessions: [SSHSession] = []

    func open(_ host: Host, store: Store) -> SSHSession {
        let s = SSHSession(host: host, store: store)
        s.onEnded = { [weak self, weak s] in
            guard let self, let s else { return }
            self.sessions.removeAll { $0.id == s.id }
        }
        sessions.append(s)
        s.connect()
        return s
    }

    /// Adds a session that never connects (App Store screenshot mode).
    func adoptDemo(host: Host, store: Store) -> SSHSession {
        let s = SSHSession(host: host, store: store)
        s.state = .connected
        sessions.append(s)
        return s
    }

    func session(_ id: UUID) -> SSHSession? { sessions.first { $0.id == id } }

    func close(_ session: SSHSession) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
    }

    func refreshAppearance() { sessions.forEach { $0.applyAppearance() } }
}
