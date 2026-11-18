import Foundation
import Crypto
import NIOSSH

enum KeyError: LocalizedError {
    case invalidFormat, encrypted, unsupported(String), missing
    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "That doesn't look like an OpenSSH or PEM private key."
        case .encrypted: return "Passphrase-protected keys aren't supported yet. Remove the passphrase with `ssh-keygen -p -f <key>` and import again."
        case .unsupported(let t): return "Key type \(t) isn't supported. Use an ed25519 or ECDSA P-256 key."
        case .missing: return "The private key for this identity is not on this device yet. If you use a sync folder, enter your secrets passphrase in Settings → Sync to restore it."
        }
    }
}

/// Generates, imports and loads SSH identities. Private key material is kept in the Keychain
/// as "<type>:<base64 raw representation>".
enum KeyManager {
    static func generate(name: String, type: String = "ed25519") -> SSHKeyRecord {
        let (blob, priv): (String, NIOSSHPrivateKey)
        if type == "ecdsa-p256" {
            let k = P256.Signing.PrivateKey()
            blob = "ecdsa-p256:" + k.rawRepresentation.base64EncodedString()
            priv = NIOSSHPrivateKey(p256Key: k)
        } else {
            let k = Curve25519.Signing.PrivateKey()
            blob = "ed25519:" + k.rawRepresentation.base64EncodedString()
            priv = NIOSSHPrivateKey(ed25519Key: k)
        }
        return store(name: name, type: type, blob: blob, key: priv)
    }

    static func importKey(name: String, text: String) throws -> SSHKeyRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try importOpenSSH(name: name, text: trimmed)
        }
        if trimmed.contains("BEGIN RSA PRIVATE KEY") { throw KeyError.unsupported("RSA") }
        if trimmed.contains("ENCRYPTED") { throw KeyError.encrypted }
        if let k = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) {
            return store(name: name, type: "ecdsa-p256", blob: "ecdsa-p256:" + k.rawRepresentation.base64EncodedString(),
                         key: NIOSSHPrivateKey(p256Key: k))
        }
        throw KeyError.invalidFormat
    }

    static func load(_ record: SSHKeyRecord) throws -> NIOSSHPrivateKey {
        guard let s = Keychain.string(account: record.keychainAccount) else { throw KeyError.missing }
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let raw = Data(base64Encoded: parts[1]) else { throw KeyError.missing }
        switch parts[0] {
        case "ed25519": return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
        case "ecdsa-p256": return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: raw))
        default: throw KeyError.unsupported(parts[0])
        }
    }

    static func fingerprint(openSSHLine: String) -> String {
        let parts = openSSHLine.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let digest = SHA256.hash(data: blob)
        return "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Private

    private static func store(name: String, type: String, blob: String, key: NIOSSHPrivateKey) -> SSHKeyRecord {
        let pub = String(openSSHPublicKey: key.publicKey)
        let comment = name.replacingOccurrences(of: " ", with: "-")
        let record = SSHKeyRecord(name: name, type: type, publicKey: "\(pub) \(comment)@tether")
        Keychain.setString(blob, account: record.keychainAccount)
        return record
    }

    private static func importOpenSSH(name: String, text: String) throws -> SSHKeyRecord {
        let body = text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: body) else { throw KeyError.invalidFormat }
        var r = Reader(data: data)
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard r.bytes(magic.count) == magic else { throw KeyError.invalidFormat }
        let cipher = try r.string()
        _ = try r.string()     // kdf name
        _ = try r.blob()       // kdf options
        guard cipher == "none" else { throw KeyError.encrypted }
        let n = try r.uint32()
        guard n >= 1 else { throw KeyError.invalidFormat }
        for _ in 0..<n { _ = try r.blob() }   // public keys
        var p = Reader(data: try r.blob())
        guard try p.uint32() == p.uint32() else { throw KeyError.invalidFormat }
        let type = try p.string()
        switch type {
        case "ssh-ed25519":
            _ = try p.blob()                       // public key
            let priv = try p.blob()                // 64 bytes: seed || public
            guard priv.count == 64 else { throw KeyError.invalidFormat }
            let k = try Curve25519.Signing.PrivateKey(rawRepresentation: priv.prefix(32))
            return store(name: name, type: "ed25519", blob: "ed25519:" + k.rawRepresentation.base64EncodedString(),
                         key: NIOSSHPrivateKey(ed25519Key: k))
        case "ecdsa-sha2-nistp256":
            _ = try p.string()                     // curve name
            _ = try p.blob()                       // Q
            var d = try p.blob()                   // mpint
            while d.count > 32, d.first == 0 { d = d.dropFirst() }
            if d.count < 32 { d = Data(repeating: 0, count: 32 - d.count) + d }
            let k = try P256.Signing.PrivateKey(rawRepresentation: d)
            return store(name: name, type: "ecdsa-p256", blob: "ecdsa-p256:" + k.rawRepresentation.base64EncodedString(),
                         key: NIOSSHPrivateKey(p256Key: k))
        case "ssh-rsa": throw KeyError.unsupported("RSA")
        default: throw KeyError.unsupported(type)
        }
    }

    private struct Reader {
        let buf: [UInt8]
        var pos = 0
        init(data: Data) { self.buf = Array(data) }
        mutating func bytes(_ n: Int) -> [UInt8]? {
            guard n >= 0, pos + n <= buf.count else { return nil }
            defer { pos += n }
            return Array(buf[pos..<pos + n])
        }
        mutating func uint32() throws -> UInt32 {
            guard let b = bytes(4) else { throw KeyError.invalidFormat }
            return b.reduce(0) { $0 << 8 | UInt32($1) }
        }
        mutating func blob() throws -> Data {
            let n = Int(try uint32())
            guard let b = bytes(n) else { throw KeyError.invalidFormat }
            return Data(b)
        }
        mutating func string() throws -> String {
            String(decoding: try blob(), as: UTF8.self)
        }
    }
}
