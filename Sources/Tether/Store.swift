import Foundation
import Observation

/// Persists hosts, keys metadata, clips, known hosts and settings as JSON.
/// Secrets (passwords, private keys) live in the Keychain.
@Observable
final class Store {
    var hosts: [Host] = [] { didSet { save() } }
    var keys: [SSHKeyRecord] = [] { didSet { save() } }
    var clips: [Clip] = [] { didSet { save() } }
    var knownHosts: [String: String] = [:] { didSet { save() } }   // "host:port" -> OpenSSH public key
    var settings = AppSettings() { didSet { save() } }

    struct Snapshot: Codable {
        var hosts: [Host]
        var keys: [SSHKeyRecord]
        var clips: [Clip]
        var knownHosts: [String: String]
        var settings: AppSettings
        /// When this data was last changed by the user (nil in files from 1.0.3 and earlier).
        var modifiedAt: Date?
    }

    /// Time of the last local change; compared against the sync folder copy.
    @ObservationIgnored private(set) var modifiedAt = Date.distantPast
    /// Called after every local change (used to push to the sync folder).
    @ObservationIgnored var onLocalChange: (() -> Void)?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tether.json")
    }()

    init() {
        loading = true
        if let data = try? Data(contentsOf: url),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            hosts = snap.hosts; keys = snap.keys; clips = snap.clips
            knownHosts = snap.knownHosts; settings = snap.settings
            modifiedAt = snap.modifiedAt ?? Date.distantPast
        } else {
            clips = [
                Clip(title: "Disk usage", text: "df -h"),
                Clip(title: "Top processes", text: "top -o %CPU", sendReturn: true),
                Clip(title: "Attach tmux", text: "tmux new -A -s main"),
            ]
        }
        loading = false
        writeLocal()
    }

    private func save() {
        guard !loading else { return }
        modifiedAt = Date()
        writeLocal()
        onLocalChange?()
    }

    private func writeLocal() {
        if let data = try? JSONEncoder().encode(snapshot()) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(hosts: hosts, keys: keys, clips: clips, knownHosts: knownHosts,
                 settings: settings, modifiedAt: modifiedAt)
    }

    /// Replaces everything with a copy from the sync folder, without counting it as a local change.
    func apply(_ snap: Snapshot) {
        loading = true
        hosts = snap.hosts; keys = snap.keys; clips = snap.clips
        knownHosts = snap.knownHosts; settings = snap.settings
        modifiedAt = snap.modifiedAt ?? Date()
        loading = false
        writeLocal()
    }

    /// True when this device has anything worth keeping over a synced copy.
    var hasUserData: Bool { !hosts.isEmpty || !keys.isEmpty || !knownHosts.isEmpty }

    // MARK: Hosts

    func upsert(_ host: Host, password: String?) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
        if let password {
            if password.isEmpty { Keychain.delete(account: host.passwordAccount) }
            else { Keychain.setString(password, account: host.passwordAccount) }
        }
    }

    func delete(host: Host) {
        Keychain.delete(account: host.passwordAccount)
        hosts.removeAll { $0.id == host.id }
        clips.removeAll { $0.hostID == host.id }
    }

    func touch(hostID: UUID) {
        if let i = hosts.firstIndex(where: { $0.id == hostID }) { hosts[i].lastConnected = Date() }
    }

    func host(_ id: UUID) -> Host? { hosts.first { $0.id == id } }

    // MARK: Keys

    func delete(key: SSHKeyRecord) {
        Keychain.delete(account: key.keychainAccount)
        keys.removeAll { $0.id == key.id }
        for i in hosts.indices where hosts[i].keyID == key.id { hosts[i].keyID = nil }
    }

    func key(_ id: UUID?) -> SSHKeyRecord? { id.flatMap { id in keys.first { $0.id == id } } }

    // MARK: Clips

    func clips(for hostID: UUID?) -> [Clip] {
        clips.filter { $0.hostID == nil || $0.hostID == hostID }
    }

    func upsert(_ clip: Clip) {
        if let i = clips.firstIndex(where: { $0.id == clip.id }) { clips[i] = clip } else { clips.append(clip) }
    }

    func theme(for host: Host?) -> Theme {
        Theme.named(host?.themeID ?? settings.themeID)
    }
}
