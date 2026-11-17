import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section("Terminal") {
                    Stepper(value: $store.settings.fontSize, in: 8...28, step: 1) {
                        LabeledContent("Font size", value: "\(Int(store.settings.fontSize)) pt")
                    }
                    Toggle("Option key as Meta", isOn: $store.settings.optionAsMeta)
                    Toggle("Haptic on bell", isOn: $store.settings.bellHaptic)
                    Toggle("Keep screen awake in sessions", isOn: $store.settings.keepScreenAwake)
                }
                Section("Theme") {
                    ForEach(Theme.all) { theme in
                        Button { store.settings.themeID = theme.id } label: {
                            HStack {
                                ThemePreview(theme: theme, fontSize: store.settings.fontSize)
                                Spacer()
                                if store.settings.themeID == theme.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section {
                    NavigationLink("Known Hosts (\(store.knownHosts.count))") { KnownHostsView() }
                } header: { Text("Security") }
                Section {
                    LabeledContent("Version", value: "1.0")
                    LabeledContent("Engine", value: "SwiftNIO SSH · SwiftTerm")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct ThemePreview: View {
    let theme: Theme
    let fontSize: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(theme.name).font(.subheadline.weight(.medium))
            VStack(alignment: .leading, spacing: 2) {
                (Text("user@host").foregroundColor(Color(UIColor(hex: theme.ansi[2])))
                 + Text(":").foregroundColor(Color(theme.uiForeground))
                 + Text("~/src").foregroundColor(Color(UIColor(hex: theme.ansi[4])))
                 + Text("$ ls").foregroundColor(Color(theme.uiForeground)))
                HStack(spacing: 3) {
                    ForEach(0..<8, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2).fill(Color(UIColor(hex: theme.ansi[i]))).frame(width: 14, height: 8)
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(10)
            .frame(width: 220, alignment: .leading)
            .background(Color(theme.uiBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }
}

struct KnownHostsView: View {
    @Environment(Store.self) private var store
    var body: some View {
        List {
            ForEach(store.knownHosts.keys.sorted(), id: \.self) { id in
                VStack(alignment: .leading, spacing: 3) {
                    Text(id).font(.body.monospaced())
                    Text(KeyManager.fingerprint(openSSHLine: store.knownHosts[id] ?? ""))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                .swipeActions { Button("Forget", role: .destructive) { store.knownHosts[id] = nil } }
            }
        }
        .overlay { if store.knownHosts.isEmpty { ContentUnavailableView("No known hosts", systemImage: "checkmark.shield") } }
        .navigationTitle("Known Hosts")
    }
}
