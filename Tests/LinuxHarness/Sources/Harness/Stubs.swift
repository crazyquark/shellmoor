import Foundation
enum Keychain {
    nonisolated(unsafe) static var items: [String: String] = [:]
    static func setString(_ s: String, account: String) { items[account] = s }
    static func string(account: String) -> String? { items[account] }
}
struct SSHKeyRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var type: String
    var publicKey: String
    var created = Date()
    var keychainAccount: String { "key.\(id.uuidString)" }
}
