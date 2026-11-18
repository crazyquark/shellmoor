import SwiftUI

struct HostEditorView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var host: Host
    @State private var password = ""
    @State private var portText = ""
    private let isNew: Bool

    init(host: Host) {
        _host = State(initialValue: host)
        _portText = State(initialValue: String(host.port))
        isNew = host.hostname.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $host.name)
                    TextField("Hostname or IP", text: $host.hostname)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", text: $portText).keyboardType(.numberPad)
                    TextField("Username", text: $host.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Group (optional)", text: $host.group)
                }
                Section {
                    Picker("Method", selection: $host.auth) {
                        ForEach(AuthMethod.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if host.auth == .password {
                        SecureField(hasStoredPassword ? "Saved — type to replace" : "Password (blank = ask each time)", text: $password)
                    } else {
                        if store.keys.isEmpty {
                            Text("No keys yet. Create one in the Keys tab.").foregroundStyle(.secondary)
                        } else {
                            Picker("Key", selection: $host.keyID) {
                                Text("None").tag(UUID?.none)
                                ForEach(store.keys) { Text($0.name).tag(UUID?.some($0.id)) }
                            }
                        }
                        SecureField("Fallback password (optional)", text: $password)
                    }
                } header: { Text("Authentication") }
                Section {
                    TextField("e.g. tmux new -A -s main", text: $host.startupCommand)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: { Text("Startup command") } footer: { Text("Runs as soon as the shell opens.") }
                Section("Appearance") {
                    Picker("Theme", selection: $host.themeID) {
                        Text("App default").tag(String?.none)
                        ForEach(Theme.all) { Text($0.name).tag(String?.some($0.id)) }
                    }
                }
            }
            .navigationTitle(isNew ? "New Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
                        host.port = Int(portText) ?? 22
                        store.upsert(host, password: password.isEmpty ? nil : password)
                        dismiss()
                    }
                    .disabled(host.hostname.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var hasStoredPassword: Bool { Keychain.string(account: host.passwordAccount) != nil }
}
