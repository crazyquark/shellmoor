import SwiftUI

@main
struct TetherApp: App {
    @State private var store: Store
    @State private var sessions: SessionManager
    @State private var sync: ConfigSync
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Diagnostics.start()
        let store = Store()
        ScreenshotMode.seed(store)
        let sessions = SessionManager()
        ScreenshotMode.openSessions(sessions, store: store)
        _store = State(initialValue: store)
        _sessions = State(initialValue: sessions)
        _sync = State(initialValue: ConfigSync(store: store))
        Keychain.migrateAll()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(sessions)
                .environment(sync)
                .tint(Color(red: 0.95, green: 0.60, blue: 0.30))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { sync.pull() }
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(SessionManager.self) private var sessions
    private enum Tab { case servers, keys, clips, settings }
    @State private var tab: Tab = {
        switch ScreenshotMode.screen {
        case .keys: return .keys
        case .settings: return .settings
        default: return .servers
        }
    }()

    var body: some View {
        TabView(selection: $tab) {
            ServersView()
                .tabItem { Label("Servers", systemImage: "server.rack") }.tag(Tab.servers)
            KeysView()
                .tabItem { Label("Keys", systemImage: "key.horizontal") }.tag(Tab.keys)
            ClipsView()
                .tabItem { Label("Clips", systemImage: "text.badge.plus") }.tag(Tab.clips)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
        }
        .onChange(of: store.settings) { _, _ in sessions.refreshAppearance() }
        .onChange(of: store.hosts) { _, _ in sessions.refreshAppearance() }
    }
}
