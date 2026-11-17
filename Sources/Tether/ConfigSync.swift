import Foundation
import Observation

/// Mirrors the Store into a JSON file inside a folder the user picked (typically in iCloud Drive).
///
/// A picked folder needs no iCloud entitlement: the Files picker hands us a security-scoped URL
/// that we keep as a bookmark. Each side carries a `modifiedAt` stamp; the newer copy wins.
/// Secrets are not in this file — they travel through iCloud Keychain (see `Keychain`).
@Observable
final class ConfigSync {
    static let fileName = "Tether Config.json"
    private static let bookmarkKey = "sync.folderBookmark"

    private(set) var folderName: String?
    private(set) var status = "Off"
    private(set) var lastSync: Date?
    /// Set when linking a folder that already has a config while this device also has data.
    var conflict: Store.Snapshot?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var folderURL: URL?
    @ObservationIgnored private let queue = DispatchQueue(label: "tether.configsync", qos: .utility)
    @ObservationIgnored private var pushWork: DispatchWorkItem?
    @ObservationIgnored private var timer: Timer?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(store: Store) {
        self.store = store
        store.onLocalChange = { [weak self] in self?.schedulePush() }
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
        Diagnostics.log("sync linked folder \(url.lastPathComponent)")
        readRemote { [weak self] remote in
            guard let self else { return }
            if let remote {
                if self.store.hasUserData { self.conflict = remote } else { self.adopt(remote) }
            } else {
                self.push()
            }
        }
        startTimer()
    }

    func unlink() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderURL = nil
        folderName = nil
        conflict = nil
        status = "Off"
        timer?.invalidate(); timer = nil
        Diagnostics.log("sync unlinked")
    }

    /// Resolves the conflict raised by `link`.
    func resolveConflict(useRemote: Bool) {
        guard let remote = conflict else { return }
        conflict = nil
        if useRemote { adopt(remote) } else { push() }
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

    // MARK: Sync

    /// Fetches the folder copy and adopts it if newer, or pushes ours if we are newer.
    func pull() {
        guard isLinked, conflict == nil else { return }
        readRemote { [weak self] remote in
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
        guard let folder = folderURL, conflict == nil else { return }
        let snap = store.snapshot()
        queue.async { [weak self] in
            let result = Self.write(snap, folder: folder)
            DispatchQueue.main.async {
                guard let self else { return }
                if let error = result {
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

    private func readRemote(_ done: @escaping (Store.Snapshot?) -> Void) {
        guard let folder = folderURL else { return }
        status = "Syncing…"
        queue.async { [weak self] in
            let (snap, error) = Self.read(folder: folder)
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.status = "Read failed: \(error)"
                    Diagnostics.log("sync read failed: \(error)")
                    return
                }
                done(snap)
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.pull() }
    }

    // MARK: File access (background queue)

    private static func read(folder: URL) -> (Store.Snapshot?, String?) {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(fileName)
        try? FileManager.default.startDownloadingUbiquitousItem(at: file)

        var coordError: NSError?
        var data: Data?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordError) { url in
            do { data = try Data(contentsOf: url) } catch { readError = error }
        }
        if let data {
            do { return (try decoder.decode(Store.Snapshot.self, from: data), nil) }
            catch { return (nil, "config file is not readable (\(error.localizedDescription))") }
        }
        if let ns = (readError ?? coordError) as NSError?,
           ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError {
            return (nil, nil)   // no config there yet
        }
        if let err = readError ?? coordError { return (nil, err.localizedDescription) }
        return (nil, nil)
    }

    private static func write(_ snap: Store.Snapshot, folder: URL) -> String? {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(fileName)
        guard let data = try? encoder.encode(snap) else { return "encode failed" }
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        return (writeError ?? coordError)?.localizedDescription
    }
}
