import Foundation
import Security

/// Generic-password storage for passwords and private keys.
///
/// When `synchronizable` is on, items are written with `kSecAttrSynchronizable` so iCloud Keychain
/// carries them to the user's other devices (end-to-end encrypted by Apple, no entitlement needed).
/// If the system refuses a synced write (possible inside LiveContainer), the item is stored
/// device-only instead and the failure is recorded in `lastSyncStatus` and the diagnostic log.
enum Keychain {
    private static let service = "io.github.crazyquark.tether"
    private static let syncDefaultsKey = "keychain.iCloudSync"

    /// Device-local preference; defaults to on.
    static var synchronizable: Bool {
        get { UserDefaults.standard.object(forKey: syncDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: syncDefaultsKey) }
    }

    /// Result of the most recent synced write: nil = none attempted yet.
    private(set) static var lastSyncStatus: OSStatus?

    /// Called after a secret is added, changed or removed (not for `local.` items or while `quietly` runs).
    static var onChange: (() -> Void)?
    private static var quiet = false

    /// Accounts with this prefix are device-only and never synced or backed up.
    static let localPrefix = "local."

    /// Runs `body` without firing `onChange` (used when importing secrets from the sync folder).
    static func quietly(_ body: () -> Void) {
        quiet = true; defer { quiet = false }
        body()
    }

    private static func notify(_ account: String) {
        if !quiet, !account.hasPrefix(localPrefix) { onChange?() }
    }

    private static func base(_ account: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    @discardableResult
    static func set(_ data: Data, account: String) -> OSStatus {
        defer { notify(account) }
        SecItemDelete(base(account) as CFDictionary)
        var add = base(account)
        add[kSecValueData as String] = data
        if synchronizable, !account.hasPrefix(localPrefix) {
            add[kSecAttrSynchronizable as String] = kCFBooleanTrue
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != lastSyncStatus {
                Diagnostics.log("keychain synced write status=\(status)")
            }
            lastSyncStatus = status
            if status == errSecSuccess { return status }
        }
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Diagnostics.log("keychain local write status=\(status)") }
        return status
    }

    static func get(account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
        notify(account)
    }

    static func setString(_ s: String, account: String) { set(Data(s.utf8), account: account) }
    static func string(account: String) -> String? { get(account: account).flatMap { String(data: $0, encoding: .utf8) } }

    /// Every item Tether owns, with whether it is currently synced.
    static func allItems() -> [(account: String, data: Data, synced: Bool)] {
        var q = base(nil)
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  !account.hasPrefix(localPrefix),
                  let data = row[kSecValueData as String] as? Data else { return nil }
            let synced = (row[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false
            return (account, data, synced)
        }
    }

    /// Rewrites every item so it matches the current `synchronizable` preference.
    /// Turning sync off makes items device-only, which also removes them from iCloud Keychain.
    static func migrateAll() {
        quietly {
            for item in allItems() where item.synced != synchronizable {
                set(item.data, account: item.account)
            }
        }
    }

    static var statusDescription: String {
        guard synchronizable else { return "Off: keys stay on this device" }
        let items = allItems()
        let synced = items.filter(\.synced).count
        if let s = lastSyncStatus, s != errSecSuccess {
            return "Unavailable (error \(s)); stored on this device only"
        }
        return items.isEmpty ? "On" : "On · \(synced) of \(items.count) items synced"
    }
}
