import Foundation

enum AuthMethod: String, Codable, CaseIterable, Identifiable {
    case password
    case key
    var id: String { rawValue }
    var label: String { self == .password ? "Password" : "SSH Key" }
}

struct Host: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String = ""
    var hostname: String = ""
    var port: Int = 22
    var username: String = ""
    var auth: AuthMethod = .password
    var keyID: UUID?
    var startupCommand: String = ""
    var themeID: String?            // nil = app default
    var group: String = ""
    var lastConnected: Date?

    var displayName: String { name.isEmpty ? hostname : name }
    var address: String {
        let base = username.isEmpty ? hostname : "\(username)@\(hostname)"
        return port == 22 ? base : "\(base):\(port)"
    }
    /// Keychain account used for the stored password.
    var passwordAccount: String { "password.\(id.uuidString)" }
}

struct SSHKeyRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var type: String               // "ed25519" or "ecdsa-p256"
    var publicKey: String          // OpenSSH public key line
    var created = Date()
    var keychainAccount: String { "key.\(id.uuidString)" }
}

struct Clip: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String = ""
    var text: String = ""
    var sendReturn: Bool = true
    var hostID: UUID?              // nil = global clip
}

struct AppSettings: Codable, Equatable {
    var fontSize: Double = 13
    var themeID: String = Theme.all[0].id
    var optionAsMeta: Bool = true
    var keepScreenAwake: Bool = false
    var bellHaptic: Bool = true
}
