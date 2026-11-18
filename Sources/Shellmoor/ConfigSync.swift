import Foundation
import Observation

/// Mirrors the Store into a JSON file inside a folder the user picked (typically in iCloud Drive),
/// and keeps a passphrase-encrypted copy of the Keychain secrets next to it.
///
/// A picked folder needs no iCloud entitlement: the Files picker hands us a security-scoped URL
/// that we keep as a bookmark. Each side carries a `modifiedAt` stamp; the newer copy wins.
/// The Keychain does not survive a reinstall inside LiveContainer, so the encrypted secrets file
/// is what brings keys and passwords back; iCloud Keychain is a bonus when it works.
@Observable
final class ConfigSync {
    static let fileName = "Shellmoor Config.json"
    static let vaultFileName = "Shellmoor Secrets.json"
    /// Names used before the app was renamed from Tether. Read when the new file doesn't exist yet;
    /// the next push writes the new name, and the old files are left alone.
    static let legacyNames = [fileName: "Tether Config.json", vaultFileName: "Tether Secrets.json"]
    private static let bookmarkKey = "sync.folderBookmark"
    private static let vaultSeenKey = "sync.vaultSeen"
    private static let vaultKeyAccount = Keychain.localPrefix + "vaultKey"

    enum VaultState: Equatable {
        case notSetUp            // no secrets file in the folder yet
        case locked(String)      // file exists, passphrase needed (reason)
        case unlocked(Int)       // number of secrets in the file
        case working(String)
        case failed(String)
    }

    private(set) var folderName: String?
    private(set) var status = "Off"
    private(set) var lastSync: Date?
    private(set) var vault: VaultState = .notSetUp
    /// Set when linking a folder that already has a config while this device also has data.
    var conflict: Store.Snapshot?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var folderURL: URL?
    @ObservationIgnored private let queue = DispatchQueue(label: "shellmoor.configsync", qos: .utility)
    @ObservationIgnored private var pushWork: DispatchWorkItem?
    @ObservationIgnored private var vaultWork: DispatchWorkItem?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var vaultKey: VaultKey?

    init(store: Store) {
        self.store = store
        store.onLocalChange = { [weak self] in self?.schedulePush() }
        Keychain.onChange = { [weak self] in self?.scheduleVaultPush() }
        if let data = Keychain.get(account: Self.vaultKeyAccount) {
            vaultKey = try? JSONDecoder().decode(VaultKey.self, from: data)
        }
        restoreBookmark()
    }

    var isLinked: Bool { folderURL != nil }

    // MARK: Linking

    func link(folder url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        } catch {
            status = "Could not remember folder: \(error.localizedDescription)"
            Diagnostics.log("sync bookmark failed: \(error)")
            return
        }
        folderURL = url
        folderName = url.lastPathComponent
        UserDefaults.standard.removeObject(forKey: Self.vaultSeenKey)
        Diagnostics.log("sync linked folder \(url.lastPathComponent)")
        readConfig { [weak self] remote in
            guard let self else { return }
            if let remote {
                if self.store.hasUserData { self.conflict = remote } else { self.adopt(remote) }
            } else {
                self.push()
            }
            self.pullVault()
        }
        startTimer()
    }

    func unlink() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderURL = nil
        folderName = nil
        conflict = nil
        status = "Off"
        vault = .notSetUp
        timer?.invalidate(); timer = nil
        Diagnostics.log("sync unlinked")
    }

    /// Resolves the conflict raised by `link`.
    func resolveConflict(useRemote: Bool) {
        guard let remote = conflict else { return }
        conflict = nil
        if useRemote { adopt(remote) } else { push() }
        pullVault()
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            folderURL = url
            folderName = url.lastPathComponent
            if stale, url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
                }
            }
            status = "Linked"
            startTimer()
        } catch {
            status = "Folder unavailable — pick it again"
            Diagnostics.log("sync bookmark resolve failed: \(error)")
        }
    }

    // MARK: Config

    /// Fetches the folder copies and adopts them if newer, or pushes ours if we are newer.
    func pull() {
        guard isLinked, conflict == nil else { return }
        readConfig { [weak self] remote in
            guard let self else { return }
            let localStamp = self.store.modifiedAt
            let remoteStamp = remote?.modifiedAt ?? .distantPast
            if let remote, remoteStamp > localStamp {
                self.adopt(remote)
            } else if remote == nil || localStamp > remoteStamp {
                self.push()
            } else {
                self.markSynced()
            }
            self.pullVault()
        }
    }

    private func adopt(_ remote: Store.Snapshot) {
        store.apply(remote)
        Diagnostics.log("sync pulled \(remote.hosts.count) hosts, \(remote.keys.count) keys")
        markSynced()
    }

    private func schedulePush() {
        guard isLinked else { return }
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.push() }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func push() {
        guard let folder = folderURL, conflict == nil,
              let data = try? SecretVault.encoder.encode(store.snapshot()) else { return }
        queue.async { [weak self] in
            let error = Self.writeFile(data, name: Self.fileName, folder: folder)
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.status = "Write failed: \(error)"
                    Diagnostics.log("sync push failed: \(error)")
                } else {
                    self.markSynced()
                }
            }
        }
    }

    private func markSynced() {
        lastSync = Date()
        status = "Up to date"
    }

    private func readConfig(_ done: @escaping (Store.Snapshot?) -> Void) {
        guard let folder = folderURL else { return }
        status = "Syncing…"
        queue.async { [weak self] in
            let result = Self.readFile(Self.fileName, folder: folder)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.status = "Read failed: \(error.message)"
                    Diagnostics.log("sync read failed: \(error.message)")
                case .success(nil):
                    done(nil)
                case .success(let data?):
                    do { done(try SecretVault.decoder.decode(Store.Snapshot.self, from: data)) }
                    catch {
                        self.status = "Config file is not readable"
                        Diagnostics.log("sync decode failed: \(error)")
                    }
                }
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.pull() }
    }

    // MARK: Encrypted secrets

    /// Keychain accounts the current config refers to; anything else is not backed up.
    private var referencedAccounts: Set<String> {
        Set(store.keys.map(\.keychainAccount) + store.hosts.map(\.passwordAccount))
    }

    private func localSecrets() -> [String: Data] {
        let wanted = referencedAccounts
        var out: [String: Data] = [:]
        for item in Keychain.allItems() where wanted.contains(item.account) { out[item.account] = item.data }
        return out
    }

    /// Reads the secrets file and imports what this device is missing (or what changed elsewhere).
    func pullVault() {
        guard let folder = folderURL else { return }
        queue.async { [weak self] in
            let result = Self.readFile(Self.vaultFileName, folder: folder)
            DispatchQueue.main.async { self?.handleVaultRead(result) }
        }
    }

    private func handleVaultRead(_ result: Result<Data?, FileError>) {
        switch result {
        case .failure(let e):
            vault = .failed(e.message)
        case .success(nil):
            if vaultKey != nil { pushVault() } else { vault = .notSetUp }
        case .success(let data?):
            guard let file = try? SecretVault.decoder.decode(VaultFile.self, from: data) else {
                vault = .failed("Secrets file is not readable"); return
            }
            guard let key = vaultKey else { vault = .locked("Enter your passphrase to restore keys and passwords."); return }
            guard key.matches(file) else {
                vault = .locked("The passphrase was changed on another device. Enter the new one.")
                return
            }
            do {
                importSecrets(try SecretVault.open(file, key: key), stamp: file.modifiedAt)
            } catch {
                vault = .locked("This device’s saved passphrase no longer opens the file.")
            }
        }
    }

    private func importSecrets(_ items: [String: Data], stamp: Date) {
        let seen = UserDefaults.standard.object(forKey: Self.vaultSeenKey) as? Date ?? .distantPast
        let newer = stamp > seen
        var imported = 0
        Keychain.quietly {
            for (account, data) in items {
                let local = Keychain.get(account: account)
                if local == nil || (newer && local != data) {
                    Keychain.set(data, account: account)
                    imported += 1
                }
            }
        }
        UserDefaults.standard.set(stamp, forKey: Self.vaultSeenKey)
        if imported > 0 { Diagnostics.log("vault imported \(imported) secrets") }
        vault = .unlocked(items.count)
        // Push back anything this device has that the file lacks.
        let local = localSecrets()
        if local.contains(where: { items[$0.key] == nil }) { pushVault() }
    }

    private func scheduleVaultPush() {
        guard isLinked, vaultKey != nil else { return }
        vaultWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pushVault() }
        vaultWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Writes the secrets file: what is already there (if `readKey` opens it) overlaid with this
    /// device's secrets, limited to accounts the config still refers to.
    private func pushVault(readKey: VaultKey? = nil) {
        guard let folder = folderURL, let writeKey = vaultKey else { return }
        let readKey = readKey ?? writeKey
        let local = localSecrets()
        let wanted = referencedAccounts
        queue.async { [weak self] in
            var merged: [String: Data] = [:]
            if case .success(let data?) = Self.readFile(Self.vaultFileName, folder: folder),
               let file = try? SecretVault.decoder.decode(VaultFile.self, from: data),
               let existing = try? SecretVault.open(file, key: readKey) {
                merged = existing
            }
            merged.merge(local) { _, mine in mine }
            merged = merged.filter { wanted.contains($0.key) }
            let stamp = Date()
            var failure: String?
            do {
                let file = try SecretVault.seal(merged, key: writeKey, modifiedAt: stamp)
                failure = Self.writeFile(try SecretVault.encoder.encode(file), name: Self.vaultFileName, folder: folder)
            } catch {
                failure = error.localizedDescription
            }
            let count = merged.count
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure {
                    self.vault = .failed("Write failed: \(failure)")
                    Diagnostics.log("vault push failed: \(failure)")
                } else {
                    UserDefaults.standard.set(stamp, forKey: Self.vaultSeenKey)
                    self.vault = .unlocked(count)
                }
            }
        }
    }

    /// First-time setup, or replacing the passphrase (or a forgotten one: the file is rewritten
    /// with this device's secrets plus whatever the old key could still open).
    func setPassphrase(_ passphrase: String) {
        let previous = vaultKey
        vault = .working("Securing…")
        queue.async { [weak self] in
            let result = Result { try SecretVault.newKey(passphrase: passphrase) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let e): self.vault = .failed(e.localizedDescription)
                case .success(let key):
                    self.saveVaultKey(key)
                    Diagnostics.log("vault passphrase set")
                    self.pushVault(readKey: previous)
                }
            }
        }
    }

    /// Unlocks an existing secrets file with its passphrase and imports its contents.
    func unlock(_ passphrase: String) {
        guard let folder = folderURL else { return }
        vault = .working("Unlocking…")
        queue.async { [weak self] in
            let outcome: Result<(VaultKey, [String: Data], Date), Error> = Result {
                guard case .success(let data?) = Self.readFile(Self.vaultFileName, folder: folder) else {
                    throw FileError(message: "Secrets file is missing")
                }
                let file = try SecretVault.decoder.decode(VaultFile.self, from: data)
                let (key, items) = try SecretVault.unlock(file, passphrase: passphrase)
                return (key, items, file.modifiedAt)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .failure(let e):
                    self.vault = .locked(e.localizedDescription)
                case .success(let (key, items, stamp)):
                    self.saveVaultKey(key)
                    UserDefaults.standard.removeObject(forKey: Self.vaultSeenKey)   // take the file's values
                    Diagnostics.log("vault unlocked, \(items.count) secrets")
                    self.importSecrets(items, stamp: stamp)
                }
            }
        }
    }

    /// Forgets the cached key on this device (the file in the folder is kept).
    func lockVault() {
        Keychain.delete(account: Self.vaultKeyAccount)
        vaultKey = nil
        vault = .locked("Locked on this device.")
    }

    private func saveVaultKey(_ key: VaultKey) {
        vaultKey = key
        if let data = try? JSONEncoder().encode(key) { Keychain.set(data, account: Self.vaultKeyAccount) }
    }

    // MARK: File access (background queue)

    struct FileError: Error { var message: String }

    private static func readFile(_ name: String, folder: URL) -> Result<Data?, FileError> {
        let result = readOne(name, folder: folder)
        if case .success(nil) = result, let legacy = legacyNames[name] {
            return readOne(legacy, folder: folder)
        }
        return result
    }

    private static func readOne(_ name: String, folder: URL) -> Result<Data?, FileError> {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(name)
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)

        var coordError: NSError?
        var data: Data?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordError) { url in
            do { data = try Data(contentsOf: url) } catch { readError = error }
        }
        if let data { return .success(data) }
        guard let err = (readError ?? coordError) as NSError? else { return .success(nil) }
        if err.domain == NSCocoaErrorDomain, err.code == NSFileReadNoSuchFileError || err.code == NSFileNoSuchFileError {
            return .success(nil)
        }
        return .failure(FileError(message: err.localizedDescription))
    }

    private static func writeFile(_ data: Data, name: String, folder: URL) -> String? {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(name)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        return (writeError ?? coordError)?.localizedDescription
    }
}
