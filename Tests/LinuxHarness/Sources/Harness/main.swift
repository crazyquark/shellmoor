import Foundation
import NIOSSH

let args = CommandLine.arguments
let dir = args[1]          // dir with test keys
let port = Int(args[2])!
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }

// 1. Key import round-trips
var records: [String: SSHKeyRecord] = [:]
for name in ["id_ed25519", "id_ecdsa"] {
    let priv = try! String(contentsOfFile: "\(dir)/\(name)", encoding: .utf8)
    let pub = try! String(contentsOfFile: "\(dir)/\(name).pub", encoding: .utf8)
    do {
        let rec = try KeyManager.importKey(name: name, text: priv)
        let expected = pub.split(separator: " ").prefix(2).joined(separator: " ")
        let got = rec.publicKey.split(separator: " ").prefix(2).joined(separator: " ")
        check(got == expected, "import \(name) public key matches ssh-keygen")
        _ = try KeyManager.load(rec)
        records[name] = rec
    } catch { check(false, "import \(name): \(error)") }
}
for name in ["id_rsa", "id_enc"] {
    let priv = try! String(contentsOfFile: "\(dir)/\(name)", encoding: .utf8)
    do { _ = try KeyManager.importKey(name: name, text: priv); check(false, "\(name) should be rejected") }
    catch { check(true, "\(name) rejected: \(error.localizedDescription)") }
}
let gen = KeyManager.generate(name: "gen")
check(gen.publicKey.hasPrefix("ssh-ed25519 "), "generated ed25519 key")
let fp = KeyManager.fingerprint(openSSHLine: try! String(contentsOfFile: "\(dir)/id_ed25519.pub", encoding: .utf8))
let expectedFP = try! String(contentsOfFile: "\(dir)/fp.txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
check(fp == expectedFP, "fingerprint matches ssh-keygen -l (\(fp))")

// 1b. Encrypted secrets file
do {
    let items = ["key.A": Data("ed25519:AAAA".utf8), "password.B": Data("hunter2".utf8)]
    let key = try SecretVault.newKey(passphrase: "correct horse")
    let file = try SecretVault.seal(items, key: key)
    let json = try SecretVault.encoder.encode(file)
    check(!String(decoding: json, as: UTF8.self).contains("hunter2"), "secrets file does not contain plaintext")
    let back = try SecretVault.decoder.decode(VaultFile.self, from: json)
    check(back == file, "secrets file JSON round-trips (exact modifiedAt)")
    let legacy = try SecretVault.decoder.decode([String: Date].self, from: Data(#"{"d":"2026-11-17T20:00:00Z"}"#.utf8))
    check(legacy["d"] == ISO8601DateFormatter().date(from: "2026-11-17T20:00:00Z"), "1.0.4 ISO dates still decode")
    let (k2, opened) = try SecretVault.unlock(back, passphrase: "correct horse")
    check(opened == items && k2 == key, "right passphrase opens and derives the same key")
    check(try SecretVault.open(back, key: k2) == items, "cached key opens the file")
    do { _ = try SecretVault.unlock(back, passphrase: "wrong"); check(false, "wrong passphrase should fail") }
    catch { check((error as? VaultError).map { if case .wrongPassphrase = $0 { return true }; return false } ?? false, "wrong passphrase rejected") }
    let other = try SecretVault.newKey(passphrase: "correct horse")
    check(!other.matches(file), "new salt is detected as a changed passphrase")
    do { _ = try SecretVault.newKey(passphrase: ""); check(false, "empty passphrase should fail") }
    catch { check(true, "empty passphrase rejected") }
} catch { check(false, "vault: \(error)") }

// 2. Live sessions against local sshd
let q = DispatchQueue(label: "cb")
func session(key: SSHKeyRecord?, trust: Bool, input: String, cols: Int = 80) -> (output: String, closed: String??, sawHostKey: String?, ended: Int??) {
    let done = DispatchSemaphore(value: 0)
    var out = [UInt8](); var closed: String?? = nil; var hostKey: String?; var ended: Int?? = nil
    let conn = SSHConnection(config: .init(hostname: "127.0.0.1", port: port, username: args.count > 3 ? args[3] : "root",
                                           privateKey: try! key.map { try KeyManager.load($0) }, storedPassword: nil,
                                           cols: cols, rows: 30), callbackQueue: q)
    conn.verifyHostKey = { line, reply in hostKey = line; reply(trust) }
    conn.requestPassword = { reply in reply(nil) }
    conn.onEvent = { ev in
        switch ev {
        case .shellReady:
            if input == "RESIZE" {
                conn.resize(cols: 77, rows: 19)
                q.asyncAfter(deadline: .now() + 0.5) { conn.send(Array("stty size\r".utf8)) }
                q.asyncAfter(deadline: .now() + 1.5) { conn.close() }
            } else if input == "LATEWRITES" {
                // Like a terminal answering queries while tmux detaches: keep writing through
                // the server's exit-status/EOF/close.
                conn.send(Array("printf '\\033[c'; exit\r".utf8))
                for i in 0..<200 { q.asyncAfter(deadline: .now() + .milliseconds(i * 2)) { conn.send(Array("\u{1b}[?1;2c".utf8)) } }
            } else { conn.send(Array(input.utf8)) }
        case .data(let b):
            out += b
            if input == "LATEWRITES" { conn.send(Array("\u{1b}[?1;2c".utf8)) }
        case .closed(let e): closed = .some(e); done.signal()
        case .ended(let st): ended = .some(st); done.signal()
        case .connected: break
        }
    }
    conn.connect()
    if done.wait(timeout: .now() + 20) == .timedOut { conn.close(); _ = done.wait(timeout: .now() + 5) }
    return (String(decoding: out, as: UTF8.self), closed, hostKey, ended)
}

for name in ["id_ed25519", "id_ecdsa"] {
    let r = session(key: records[name], trust: true, input: "echo hello-$((40+2)); stty size; echo $TERM; exit\r", cols: 101)
    check(r.output.contains("hello-42"), "\(name): shell ran command")
    check(r.output.contains("30 101"), "\(name): PTY size 30x101 applied")
    check(r.output.contains("xterm-256color"), "\(name): TERM set")
    check(r.ended == .some(0) && r.closed == nil, "\(name): exit reported as ended with status 0 (ended \(String(describing: r.ended)), closed \(String(describing: r.closed)))")
    check(r.sawHostKey?.hasPrefix("ssh-ed25519") == true || r.sawHostKey?.hasPrefix("ecdsa") == true, "host key presented: \(r.sawHostKey ?? "nil")")
}
let failing = session(key: records["id_ed25519"], trust: true, input: "exit 3\r")
check(failing.ended == .some(3), "non-zero exit status passed through (\(String(describing: failing.ended)))")
for i in 1...5 {
    let late = session(key: records["id_ed25519"], trust: true, input: "LATEWRITES")
    check(late.ended != nil && late.closed == nil, "writes racing the server's close are not an error, run \(i) (ended \(String(describing: late.ended)), closed \(String(describing: late.closed)))")
}
let rs = session(key: records["id_ed25519"], trust: true, input: "RESIZE")
check(rs.output.contains("19 77"), "live window-change resize applied")
check(rs.closed == .some(nil), "user-initiated close reported as clean (\(String(describing: rs.closed)))")
let rejected = session(key: records["id_ed25519"], trust: false, input: "")
check(rejected.closed == .some(SessionError.hostKeyRejected.errorDescription), "host key rejection closes with message (\(String(describing: rejected.closed)))")
let wrongKey = session(key: gen, trust: true, input: "")
check(wrongKey.closed == .some(SessionError.authFailed.errorDescription) || wrongKey.closed == .some(SessionError.cancelled.errorDescription), "unauthorized key fails auth (\(String(describing: wrongKey.closed)))")
let refused = { () -> String?? in
    let done = DispatchSemaphore(value: 0); var c: String?? = nil
    let conn = SSHConnection(config: .init(hostname: "127.0.0.1", port: 1, username: "x", privateKey: nil, storedPassword: nil), callbackQueue: q)
    conn.onEvent = { if case .closed(let e) = $0 { c = .some(e); done.signal() } }
    conn.connect(); _ = done.wait(timeout: .now() + 10); return c
}()
check((refused ?? nil)?.contains("Couldn't reach") == true, "connection refused message: \(String(describing: refused))")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
