import SwiftUI
import UniformTypeIdentifiers

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
                SyncSection()
                Section {
                    NavigationLink("Known Hosts (\(store.knownHosts.count))") { KnownHostsView() }
                } header: { Text("Security") }
                Section {
                    NavigationLink("Diagnostic Log") { DiagnosticsView() }
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                    LabeledContent("Engine", value: "SwiftNIO SSH · SwiftTerm")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct SyncSection: View {
    @Environment(ConfigSync.self) private var sync
    @State private var picking = false
    @State private var keychainSync = Keychain.synchronizable
    @State private var keychainStatus = Keychain.statusDescription

    var body: some View {
        @Bindable var sync = sync
        Section {
            if let name = sync.folderName {
                LabeledContent("Folder", value: name)
                LabeledContent("Status", value: sync.status)
                if let last = sync.lastSync {
                    LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .shortened))
                }
                Button("Sync Now") { sync.pull() }
                VaultRows()
                Button("Change Folder…") { picking = true }
                Button("Stop Syncing Config", role: .destructive) { sync.unlink() }
            } else {
                Button("Choose iCloud Drive Folder…") { picking = true }
            }
            Toggle("Keys & Passwords in iCloud Keychain", isOn: $keychainSync)
                .onChange(of: keychainSync) { _, on in
                    Keychain.synchronizable = on
                    Keychain.migrateAll()
                    keychainStatus = Keychain.statusDescription
                }
            Text(keychainStatus).font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Sync")
        } footer: {
            Text("Servers, key names, clips, known hosts and settings are saved as “\(ConfigSync.fileName)” in the chosen folder. Private keys and passwords go in “\(ConfigSync.vaultFileName)”, encrypted with your passphrase, which never leaves this device. iCloud Keychain is used as well when the system allows it.")
        }
        .onAppear { keychainStatus = Keychain.statusDescription }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { sync.link(folder: url) }
        }
        .confirmationDialog("This folder already has a Tether config",
                            isPresented: Binding(get: { sync.conflict != nil },
                                                 set: { if !$0, sync.conflict != nil { sync.unlink() } }),
                            titleVisibility: .visible) {
            Button("Use the Folder's Copy") { sync.resolveConflict(useRemote: true) }
            Button("Replace It with This Device's") { sync.resolveConflict(useRemote: false) }
            Button("Cancel", role: .cancel) { sync.unlink() }
        } message: {
            if let c = sync.conflict {
                Text("The folder copy has \(c.hosts.count) servers and \(c.keys.count) keys. Choosing one replaces the other.")
            }
        }
    }
}

/// Status and actions for the passphrase-encrypted secrets file.
struct VaultRows: View {
    @Environment(ConfigSync.self) private var sync
    private enum Prompt: Identifiable { case setUp, unlock, change; var id: Self { self } }
    @State private var prompt: Prompt?
    @State private var first = ""
    @State private var second = ""
    @State private var mismatch = false

    var body: some View {
        Group { rows }
            .alert(title, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
                SecureField("Passphrase", text: $first)
                if prompt != .unlock { SecureField("Repeat passphrase", text: $second) }
                Button("Cancel", role: .cancel) {}
                Button(prompt == .unlock ? "Unlock" : "Save") { submit() }
            } message: {
                Text(message)
            }
            .alert("Passphrases don’t match", isPresented: $mismatch) { Button("OK") {} }
    }

    @ViewBuilder private var rows: some View {
        switch sync.vault {
        case .notSetUp:
            LabeledContent("Keys & passwords", value: "Not backed up")
            Button("Set Up Secrets Passphrase…") { ask(.setUp) }
        case .locked(let reason):
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Keys & passwords", value: "Locked")
                Text(reason).font(.footnote).foregroundStyle(.orange)
            }
            Button("Enter Passphrase…") { ask(.unlock) }
            Button("Forgot It? Set a New One…") { ask(.change) }
        case .unlocked(let n):
            LabeledContent("Keys & passwords", value: "\(n) encrypted")
            Button("Change Passphrase…") { ask(.change) }
        case .working(let s):
            LabeledContent(s) { ProgressView() }
        case .failed(let s):
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Keys & passwords", value: "Error")
                Text(s).font(.footnote).foregroundStyle(.red)
            }
            Button("Retry") { sync.pullVault() }
        }
    }

    private var title: String {
        switch prompt {
        case .unlock: return "Enter Passphrase"
        case .change: return "New Passphrase"
        default: return "Secrets Passphrase"
        }
    }

    private var message: String {
        switch prompt {
        case .unlock: return "The passphrase you chose on your other device."
        case .change: return "Your other devices will ask for the new passphrase. If you forgot the old one, secrets only on other devices are lost."
        default: return "Encrypts your keys and passwords in the sync folder. You’ll enter it once on each device. It can’t be recovered."
        }
    }

    private func ask(_ p: Prompt) { first = ""; second = ""; prompt = p }

    private func submit() {
        let p = prompt; prompt = nil
        guard !first.isEmpty else { return }
        if p == .unlock { sync.unlock(first); return }
        guard first == second else { mismatch = true; return }
        sync.setPassphrase(first)
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

struct DiagnosticsView: View {
    @State private var text = Diagnostics.read()
    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Log is empty." : text)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Diagnostic Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: Diagnostics.logURL)
            Button("Clear") { Diagnostics.clear(); text = "" }
        }
    }
}
