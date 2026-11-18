import Foundation
import Crypto
import CryptoExtras

/// Passphrase-encrypted container for Keychain items, stored next to the config in the sync folder.
///
/// Key: PBKDF2-SHA256 (600k rounds, 16-byte random salt) → 256-bit key. Contents: AES-256-GCM over a
/// JSON map of keychain account → secret bytes. A wrong passphrase shows up as an authentication failure.
struct VaultFile: Codable, Equatable {
    var version = 1
    var kdf = "pbkdf2-sha256"
    var rounds: Int
    var salt: Data
    var box: Data          // AES.GCM combined (nonce | ciphertext | tag)
    var modifiedAt: Date
}

/// A derived key plus the parameters it came from, cached on-device so the passphrase is asked once.
struct VaultKey: Codable, Equatable {
    var salt: Data
    var rounds: Int
    var key: Data

    var symmetric: SymmetricKey { SymmetricKey(data: key) }
    func matches(_ file: VaultFile) -> Bool { file.salt == salt && file.rounds == rounds }
}

enum VaultError: LocalizedError {
    case wrongPassphrase, unsupported(String), emptyPassphrase

    var errorDescription: String? {
        switch self {
        case .wrongPassphrase: return "Wrong passphrase."
        case .unsupported(let s): return "Unsupported secrets file (\(s))."
        case .emptyPassphrase: return "The passphrase can’t be empty."
        }
    }
}

enum SecretVault {
    static let defaultRounds = 600_000

    static func newKey(passphrase: String, rounds: Int = defaultRounds) throws -> VaultKey {
        var salt = Data(count: 16)
        for i in salt.indices { salt[i] = UInt8.random(in: 0...255) }
        return try deriveKey(passphrase: passphrase, salt: salt, rounds: rounds)
    }

    static func deriveKey(passphrase: String, salt: Data, rounds: Int) throws -> VaultKey {
        guard !passphrase.isEmpty else { throw VaultError.emptyPassphrase }
        let k = try KDF.Insecure.PBKDF2.deriveKey(from: Data(passphrase.utf8), salt: salt, using: .sha256,
                                                  outputByteCount: 32, rounds: rounds)
        return VaultKey(salt: salt, rounds: rounds, key: k.withUnsafeBytes { Data($0) })
    }

    /// Derives the key for an existing file from a passphrase and checks it opens the file.
    static func unlock(_ file: VaultFile, passphrase: String) throws -> (VaultKey, [String: Data]) {
        try check(file)
        let key = try deriveKey(passphrase: passphrase, salt: file.salt, rounds: file.rounds)
        return (key, try open(file, key: key))
    }

    static func seal(_ items: [String: Data], key: VaultKey, modifiedAt: Date = Date()) throws -> VaultFile {
        let plain = try JSONEncoder().encode(items)
        let box = try AES.GCM.seal(plain, using: key.symmetric)
        guard let combined = box.combined else { throw VaultError.unsupported("nonce") }
        return VaultFile(rounds: key.rounds, salt: key.salt, box: combined, modifiedAt: modifiedAt)
    }

    static func open(_ file: VaultFile, key: VaultKey) throws -> [String: Data] {
        try check(file)
        guard key.matches(file) else { throw VaultError.wrongPassphrase }
        let plain: Data
        do {
            plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: file.box), using: key.symmetric)
        } catch {
            throw VaultError.wrongPassphrase
        }
        return try JSONDecoder().decode([String: Data].self, from: plain)
    }

    private static func check(_ file: VaultFile) throws {
        guard file.version == 1, file.kdf == "pbkdf2-sha256" else {
            throw VaultError.unsupported("v\(file.version) \(file.kdf)")
        }
    }

    /// Coders for files in the sync folder. Dates are written as exact seconds-since-2001 so a
    /// stamp read back compares equal to the one written (ISO-8601 drops fractions, which made the
    /// writer think its copy was always newer). ISO strings from 1.0.4 are still accepted.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let t = try? c.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: t) }
            let s = try c.decode(String.self)
            guard let date = ISO8601DateFormatter().date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }()
}
