import SwiftUI
import UniformTypeIdentifiers

struct KeysView: View {
    @Environment(Store.self) private var store
    @State private var showImport = false
    @State private var showGenerate = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.keys) { key in
                    NavigationLink { KeyDetailView(key: key) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(key.name).font(.body.weight(.medium))
                                Text(key.type).font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            Text(KeyManager.fingerprint(openSSHLine: key.publicKey))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { store.delete(key: key) } }
                }
            }
            .overlay {
                if store.keys.isEmpty {
                    ContentUnavailableView {
                        Label("No keys", systemImage: "key.horizontal")
                    } description: {
                        Text("Generate a key on this device or import an existing ed25519 / ECDSA key.")
                    } actions: {
                        Button("Generate Key") { showGenerate = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Keys")
            .toolbar {
                Menu {
                    Button { showGenerate = true } label: { Label("Generate New Key", systemImage: "wand.and.stars") }
                    Button { showImport = true } label: { Label("Import Key", systemImage: "square.and.arrow.down") }
                } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showGenerate) { GenerateKeySheet() }
            .sheet(isPresented: $showImport) { ImportKeySheet() }
        }
    }
}

struct KeyDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let key: SSHKeyRecord
    @State private var copied = false

    var body: some View {
        List {
            Section("Public key") {
                Text(key.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                Button { UIPasteboard.general.string = key.publicKey; copied = true } label: {
                    Label(copied ? "Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: key.publicKey) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
            }
            Section {
                Text("Append the public key to `~/.ssh/authorized_keys` on the server.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(verbatim: "echo '\(key.publicKey)' >> ~/.ssh/authorized_keys")
                    .font(.caption2.monospaced()).textSelection(.enabled)
            } header: { Text("Install") }
            Section("Details") {
                LabeledContent("Type", value: key.type)
                LabeledContent("Fingerprint") {
                    Text(KeyManager.fingerprint(openSSHLine: key.publicKey)).font(.caption2.monospaced()).multilineTextAlignment(.trailing)
                }
                LabeledContent("Created", value: key.created.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Used by", value: "\(store.hosts.filter { $0.keyID == key.id }.count) servers")
            }
            Section {
                Button("Delete Key", role: .destructive) { store.delete(key: key); dismiss() }
            }
        }
        .navigationTitle(key.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct GenerateKeySheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = UIDevice.current.name
    @State private var type = "ed25519"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Type", selection: $type) {
                    Text("Ed25519 (recommended)").tag("ed25519")
                    Text("ECDSA P-256").tag("ecdsa-p256")
                }
            }
            .navigationTitle("Generate Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        store.keys.append(KeyManager.generate(name: name.isEmpty ? "key" : name, type: type))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ImportKeySheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var error: String?
    @State private var pickFile = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section {
                    TextEditor(text: $text)
                        .font(.caption.monospaced())
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { text = UIPasteboard.general.string ?? "" } label: { Label("Paste from Clipboard", systemImage: "doc.on.clipboard") }
                    Button { pickFile = true } label: { Label("Choose File…", systemImage: "folder") }
                } header: { Text("Private key") } footer: {
                    Text("OpenSSH (-----BEGIN OPENSSH PRIVATE KEY-----) or PEM. Ed25519 and ECDSA P-256 keys without a passphrase.")
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $pickFile, allowedContentTypes: [.data, .text]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            store.keys.append(try KeyManager.importKey(name: name.isEmpty ? "imported" : name, text: text))
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(text.isEmpty)
                }
            }
        }
    }
}
