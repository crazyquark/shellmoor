import Foundation

/// App Store screenshot mode, used only by `scripts/screenshots.sh` in CI.
///
/// Launching with `-ShellmoorScreenshot <screen>` (servers, terminal, keys or settings) fills the
/// app with demo servers, keys and two sessions showing canned terminal output, then opens
/// that screen. Nothing connects anywhere. Launch arguments of the form `-key value` land in
/// UserDefaults, so no extra parsing is needed. Without the argument this does nothing.
enum ScreenshotMode {
    enum Screen: String {
        case servers, terminal, keys, settings
    }

    static let screen: Screen? = UserDefaults.standard.string(forKey: "ShellmoorScreenshot").flatMap(Screen.init)
    static var isActive: Bool { screen != nil }

    /// The session the terminal screenshot opens.
    private(set) static var terminalSessionID: UUID?

    /// Replaces the store's contents with demo data. Call once, at launch.
    static func seed(_ store: Store) {
        guard isActive else { return }
        let now = Date()
        func host(_ name: String, _ hostname: String, _ user: String, group: String, ago: TimeInterval?,
                  auth: AuthMethod = .key, theme: String? = nil, port: Int = 22) -> Host {
            var h = Host()
            h.name = name; h.hostname = hostname; h.username = user; h.group = group
            h.auth = auth; h.themeID = theme; h.port = port
            h.lastConnected = ago.map { now.addingTimeInterval(-$0) }
            return h
        }
        if store.keys.isEmpty {
            store.keys = [
                KeyManager.generate(name: "iPhone", type: "ed25519"),
                KeyManager.generate(name: "Deploy (CI)", type: "ecdsa-p256"),
            ]
        }
        let key = store.keys.first?.id
        var hosts = [
            host("web-1", "web-1.example.com", "deploy", group: "Production", ago: 120),
            host("web-2", "web-2.example.com", "deploy", group: "Production", ago: 86_400),
            host("db-primary", "db.example.com", "postgres", group: "Production", ago: 3 * 86_400),
            host("staging", "staging.example.com", "deploy", group: "Staging", ago: 7_200, port: 2222),
            host("nas", "nas.local", "admin", group: "Home", ago: 600, theme: "matrix"),
            host("pi-hole", "pihole.local", "pi", group: "Home", ago: 5 * 86_400, auth: .password),
        ]
        for i in hosts.indices where hosts[i].auth == .key { hosts[i].keyID = key }
        hosts[4].startupCommand = "tmux new -A -s main"
        store.hosts = hosts
        store.clips = [
            Clip(title: "Disk usage", text: "df -h"),
            Clip(title: "Tail app log", text: "journalctl -u app -f"),
            Clip(title: "Attach tmux", text: "tmux new -A -s main"),
            Clip(title: "Top processes", text: "top -o %CPU"),
        ]
        let hostKey = store.keys.first?.publicKey ?? ""
        store.knownHosts = Dictionary(uniqueKeysWithValues: hosts.map { ("\($0.hostname):\($0.port)", hostKey) })
    }

    /// Opens two demo sessions with canned output (no network).
    static func openSessions(_ sessions: SessionManager, store: Store) {
        guard isActive else { return }
        let web = store.hosts.first { $0.name == "web-1" }
        let nas = store.hosts.first { $0.name == "nas" }
        if let web {
            let s = sessions.adoptDemo(host: web, store: store)
            s.terminalView.feed(text: webTranscript)
            terminalSessionID = s.id
        }
        if let nas {
            let s = sessions.adoptDemo(host: nas, store: store)
            s.terminalView.feed(text: "admin@nas:~$ ")
        }
    }

    // MARK: Canned output (kept under ~50 columns so it fits an iPhone in portrait)

    private static let reset = "\u{1b}[0m"
    private static func c(_ code: String, _ s: String) -> String { "\u{1b}[\(code)m\(s)\(reset)" }
    private static var prompt: String {
        c("1;32", "deploy@web-1") + ":" + c("1;34", "~/app") + "$ "
    }

    private static var webTranscript: String {
        let lines: [String] = [
            "Last login: Tue Nov 17 09:12:44 2026",
            prompt + "git log --oneline --graph -6",
            "* " + c("33", "3f9c2e1") + " (" + c("1;36", "HEAD -> ") + c("1;32", "main") + ", " + c("1;31", "origin/main") + ") Cache pages",
            "* " + c("33", "a71d0b4") + " Add health check",
            "*   " + c("33", "9e02f5c") + " Merge branch 'search'",
            c("31", "|") + c("32", "\\"),
            c("31", "|") + " " + c("32", "*") + " " + c("33", "51be7aa") + " Index titles for search",
            "* " + c("32", "|") + " " + c("33", "c4d8e19") + " Bump dependencies",
            c("32", "|/"),
            "* " + c("33", "0b6e3a2") + " Release 2.4.0",
            prompt + "systemctl status app --no-pager",
            c("1;32", "●") + " app.service - App server",
            "     Loaded: loaded (enabled; preset: enabled)",
            "     Active: " + c("1;32", "active (running)") + " since Mon 08:02",
            "   Main PID: 1824 (app)",
            "      Tasks: 12 (limit: 4915)",
            "     Memory: 86.3M",
            prompt + "ls",
            "Dockerfile  README.md  " + c("1;34", "config") + "  " + c("1;34", "public") + "  " + c("1;34", "src") + "  " + c("1;34", "tests"),
            prompt + "df -h /",
            "Filesystem      Size  Used Avail Use% Mounted on",
            "/dev/sda1        80G   31G   46G  41% /",
        ]
        return lines.joined(separator: "\r\n") + "\r\n" + prompt
    }
}
