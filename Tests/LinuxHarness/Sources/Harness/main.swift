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

// 2. Live sessions against local sshd
let q = DispatchQueue(label: "cb")
func session(key: SSHKeyRecord?, trust: Bool, input: String, cols: Int = 80) -> (output: String, closed: String??, sawHostKey: String?) {
    let done = DispatchSemaphore(value: 0)
    var out = [UInt8](); var closed: String?? = nil; var hostKey: String?
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
            } else { conn.send(Array(input.utf8)) }
        case .data(let b): out += b
        case .closed(let e): closed = .some(e); done.signal()
        case .connected: break
        }
    }
    conn.connect()
    if done.wait(timeout: .now() + 20) == .timedOut { conn.close(); _ = done.wait(timeout: .now() + 5) }
    return (String(decoding: out, as: UTF8.self), closed, hostKey)
}

for name in ["id_ed25519", "id_ecdsa"] {
    let r = session(key: records[name], trust: true, input: "echo hello-$((40+2)); stty size; echo $TERM; exit\r", cols: 101)
    check(r.output.contains("hello-42"), "\(name): shell ran command")
    check(r.output.contains("30 101"), "\(name): PTY size 30x101 applied")
    check(r.output.contains("xterm-256color"), "\(name): TERM set")
    check(r.closed == .some(nil), "\(name): clean close on exit (\(String(describing: r.closed)))")
    check(r.sawHostKey?.hasPrefix("ssh-ed25519") == true || r.sawHostKey?.hasPrefix("ecdsa") == true, "host key presented: \(r.sawHostKey ?? "nil")")
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
