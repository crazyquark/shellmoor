import SwiftUI

struct ClipsView: View {
    @Environment(Store.self) private var store
    @State private var editing: Clip?

    var body: some View {
        NavigationStack {
            List {
                let global = store.clips.filter { $0.hostID == nil }
                if !global.isEmpty {
                    Section("Global") { ForEach(global) { row($0) } }
                }
                ForEach(store.hosts) { host in
                    let mine = store.clips.filter { $0.hostID == host.id }
                    if !mine.isEmpty { Section(host.displayName) { ForEach(mine) { row($0) } } }
                }
            }
            .overlay {
                if store.clips.isEmpty {
                    ContentUnavailableView("No clips", systemImage: "text.badge.plus",
                                           description: Text("Clips are commands you send with one tap from the terminal."))
                }
            }
            .navigationTitle("Clips")
            .toolbar { Button { editing = Clip() } label: { Image(systemName: "plus") } }
            .sheet(item: $editing) { ClipEditor(clip: $0) }
        }
    }

    private func row(_ clip: Clip) -> some View {
        Button { editing = clip } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.title.isEmpty ? "Untitled" : clip.title).foregroundStyle(.primary)
                Text(clip.text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .swipeActions { Button("Delete", role: .destructive) { store.clips.removeAll { $0.id == clip.id } } }
    }
}

struct ClipEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var clip: Clip

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $clip.title)
                Section("Text") {
                    TextEditor(text: $clip.text)
                        .font(.body.monospaced()).frame(minHeight: 100)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Toggle("Press Return after sending", isOn: $clip.sendReturn)
                Picker("Available on", selection: $clip.hostID) {
                    Text("All servers").tag(UUID?.none)
                    ForEach(store.hosts) { Text($0.displayName).tag(UUID?.some($0.id)) }
                }
            }
            .navigationTitle("Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.upsert(clip); dismiss() }.disabled(clip.text.isEmpty)
                }
            }
        }
    }
}
