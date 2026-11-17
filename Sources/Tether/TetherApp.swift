import SwiftUI

@main
struct TetherApp: App {
    @State private var store: Store
    @State private var sessions = SessionManager()

    init() {
        Diagnostics.start()
        _store = State(initialValue: Store())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(sessions)
                .tint(Color(red: 0.95, green: 0.60, blue: 0.30))
        }
    }
}

struct RootView: View {
    @Environment(Store.self) private var store
    @Environment(SessionManager.self) private var sessions

    var body: some View {
        TabView {
            ServersView()
                .tabItem { Label("Servers", systemImage: "server.rack") }
            KeysView()
                .tabItem { Label("Keys", systemImage: "key.horizontal") }
            ClipsView()
                .tabItem { Label("Clips", systemImage: "text.badge.plus") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onChange(of: store.settings) { _, _ in sessions.refreshAppearance() }
        .onChange(of: store.hosts) { _, _ in sessions.refreshAppearance() }
    }
}
