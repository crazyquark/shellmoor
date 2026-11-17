import Foundation

/// Writes a log file to Documents (visible in the Files app under "Tether") and captures
/// crashes: Swift runtime errors print to stderr, which is redirected into the log, and
/// signal/exception handlers append a backtrace.
enum Diagnostics {
    static let logURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tether.log")

    static func start() {
        // Keep the log small: start over once it passes 512 KB.
        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 512_000 {
            try? FileManager.default.removeItem(at: logURL)
        }
        freopen(logURL.path, "a", stderr)
        setvbuf(stderr, nil, _IONBF, 0)
        let info = Bundle.main.infoDictionary
        log("=== Launch \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")) ===")

        NSSetUncaughtExceptionHandler { e in
            Diagnostics.log("CRASH uncaught exception \(e.name.rawValue): \(e.reason ?? "")\n" +
                            e.callStackSymbols.joined(separator: "\n"))
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                fputs("CRASH signal \(s)\n" + Thread.callStackSymbols.joined(separator: "\n") + "\n", stderr)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        fputs("[\(ts)] \(message)\n", stderr)
    }

    static func read() -> String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    static func clear() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        freopen(logURL.path, "a", stderr)
    }
}
