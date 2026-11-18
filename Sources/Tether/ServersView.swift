import SwiftUI

struct ServersView: View {
    @Environment(Store.self) private var store
    @Environment(SessionManager.self) private var sessions
    @State private var path: [UUID] = {
        if ScreenshotMode.screen == .terminal, let id = ScreenshotMode.terminalSessionID { return [id] }
        return []
    }()
    @State private var editing: Host?
    @State private var search = ""

    private var filtered: [Host] {
        let q = search.lowercased()
        let list = q.isEmpty ? store.hosts : store.hosts.filter {
            $0.displayName.lowercased().contains(q) || $0.address.lowercased().contains(q) || $0.group.lowercased().contains(q)
        }
        return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var groups: [(String, [Host])] {
        Dictionary(grouping: filtered, by: { $0.group }).sorted { a, b in
            if a.key.isEmpty { return false }; if b.key.isEmpty { return true }
            return a.key < b.key
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !sessions.sessions.isEmpty && search.isEmpty {
                    Section("Active") {
                        ForEach(sessions.sessions) { s in
                            NavigationLink(value: s.id) { SessionRow(session: s) }
                                .swipeActions {
                                    Button("Close", role: .destructive) { sessions.close(s) }
                                }
                        }
                    }
                }
                ForEach(groups, id: \.0) { group, hosts in
                    Section(group.isEmpty ? (groups.count > 1 ? "Other" : "Servers") : group) {
                        ForEach(hosts) { host in
                            Button { connect(host) } label: { HostRow(host: host) }
                                .foregroundStyle(.primary)
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) { store.delete(host: host) }
                                    Button("Edit") { editing = host }.tint(.gray)
                                }
                                .contextMenu {
                                    Button { connect(host) } label: { Label("Connect", systemImage: "play") }
                                    Button { editing = host } label: { Label("Edit", systemImage: "pencil") }
                                    Button {
                                        var copy = host; copy.id = UUID(); copy.name = host.displayName + " copy"; copy.lastConnected = nil
                                        store.upsert(copy, password: Keychain.string(account: host.passwordAccount))
                                    } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                                    Button(role: .destructive) { store.delete(host: host) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .overlay {
                if store.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No servers yet", systemImage: "server.rack")
                    } description: {
                        Text("Add a server to open an SSH session.")
                    } actions: {
                        Button("Add Server") { editing = Host() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .searchable(text: $search, prompt: "Search servers")
            .navigationTitle("Tether")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = Host() } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let s = sessions.session(id) { TerminalScreen(session: s) }
            }
            .sheet(item: $editing) { host in HostEditorView(host: host) }
        }
    }

    private func connect(_ host: Host) {
        let s = sessions.open(host, store: store)
        path.append(s.id)
    }
}

struct HostRow: View {
    @Environment(Store.self) private var store
    let host: Host
    var body: some View {
        HStack(spacing: 12) {
            let theme = store.theme(for: host)
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(theme.uiBackground))
                .frame(width: 36, height: 36)
                .overlay(Text(">_").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Color(theme.uiCursor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName).font(.body.weight(.medium))
                Text(host.address).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: host.auth == .key ? "key.horizontal" : "lock")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct SessionRow: View {
    let session: SSHSession
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(session.host.address) · \(session.state.label)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    private var color: Color {
        switch session.state {
        case .connected: return .green
        case .connecting, .authenticating: return .orange
        case .disconnected: return .gray
        }
    }
}
