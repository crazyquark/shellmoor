import SwiftUI
import SwiftTerm

/// Hosts the session's long-lived TerminalView inside a container so the view can move
/// between SwiftUI hierarchies without being recreated.
struct TerminalContainer: UIViewRepresentable {
    let session: SSHSession

    func makeUIView(context: Context) -> UIView {
        Diagnostics.log("terminal view attach")
        let container = UIView()
        container.backgroundColor = session.terminalView.backgroundColor
        let tv = session.terminalView
        tv.removeFromSuperview()
        tv.frame = container.bounds
        tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(tv)
        // No keyboard in App Store screenshots: it would hide half the session.
        if !ScreenshotMode.isActive { DispatchQueue.main.async { _ = tv.becomeFirstResponder() } }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.backgroundColor = session.terminalView.backgroundColor
    }
}

struct TerminalScreen: View {
    @Environment(Store.self) private var store
    @Environment(SessionManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: SSHSession
    @State private var showClips = true
    @State private var password = ""
    @State private var rememberPassword = false

    var body: some View {
        let theme = store.theme(for: store.host(session.host.id) ?? session.host)
        VStack(spacing: 0) {
            TerminalContainer(session: session)
            if showClips && !clips.isEmpty { clipBar(theme: theme) }
        }
        .background(Color(theme.uiBackground).ignoresSafeArea())
        .overlay(alignment: .top) { statusBanner }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(theme.uiBackground), for: .navigationBar)
        .toolbarColorScheme(theme.isDark ? .dark : .light, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { toggleKeyboard() } label: { Image(systemName: "keyboard") }
                Menu {
                    Button { if let s = UIPasteboard.general.string { session.send(text: s) } } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                    Toggle(isOn: $showClips) { Label("Clips Bar", systemImage: "text.badge.plus") }
                    Divider()
                    if session.state.isLive {
                        Button(role: .destructive) { session.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    } else {
                        Button { session.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    }
                    Button(role: .destructive) { sessions.close(session); dismiss() } label: {
                        Label("Close Session", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = store.settings.keepScreenAwake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(item: $session.hostKeyPrompt) { prompt in
            HostKeySheet(prompt: prompt, host: session.host) { trust in session.resolveHostKey(trust: trust) }
                .interactiveDismissDisabled()
        }
        .alert("Password for \(session.host.address)", isPresented: $session.passwordPrompt) {
            SecureField("Password", text: $password)
            Button("Connect") { session.resolvePassword(password, remember: false); password = "" }
            Button("Connect & Save") { session.resolvePassword(password, remember: true); password = "" }
            Button("Cancel", role: .cancel) { session.resolvePassword(nil); password = "" }
        }
    }

    private var clips: [Clip] { store.clips(for: session.host.id) }

    private func clipBar(theme: Theme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(clips) { clip in
                    Button {
                        session.send(text: clip.text + (clip.sendReturn ? "\r" : ""))
                    } label: {
                        HStack(spacing: 4) {
                            if clip.hostID != nil { Image(systemName: "pin.fill").font(.system(size: 9)) }
                            Text(clip.title.isEmpty ? clip.text : clip.title).lineLimit(1)
                        }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Color(theme.uiForeground).opacity(0.12)))
                        .foregroundStyle(Color(theme.uiForeground))
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Color(theme.uiBackground))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    @ViewBuilder private var statusBanner: some View {
        switch session.state {
        case .connected:
            EmptyView()
        case .connecting, .authenticating:
            Label(session.state.label, systemImage: "antenna.radiowaves.left.and.right")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
        case .disconnected(let err):
            HStack(spacing: 10) {
                Image(systemName: err == nil ? "bolt.horizontal.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(err == nil ? Color.secondary : Color.orange)
                Text(err ?? "Disconnected").font(.footnote).lineLimit(2)
                Button("Reconnect") { session.reconnect() }
                    .font(.footnote.weight(.semibold)).buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal).padding(.top, 8)
        }
    }

    private func toggleKeyboard() {
        let tv = session.terminalView
        if tv.isFirstResponder { _ = tv.resignFirstResponder() } else { _ = tv.becomeFirstResponder() }
    }
}

struct HostKeySheet: View {
    let prompt: HostKeyPrompt
    let host: Host
    let decide: (Bool) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if let previous = prompt.previousFingerprint {
                    Label("Host key changed", systemImage: "exclamationmark.shield.fill")
                        .font(.title2.bold()).foregroundStyle(.red)
                    Text("The key presented by \(host.hostname) doesn't match the one you trusted before. Someone may be intercepting the connection, or the server was reinstalled.")
                    field("Previously trusted", previous)
                } else {
                    Label("Unknown server", systemImage: "questionmark.diamond.fill")
                        .font(.title2.bold())
                    Text("This is the first time you're connecting to \(host.hostname). Check that the fingerprint below matches the server's before trusting it.")
                }
                field("\(prompt.keyLine.split(separator: " ").first ?? "") fingerprint", prompt.fingerprint)
                Spacer()
                Button { decide(true) } label: {
                    Text(prompt.previousFingerprint == nil ? "Trust and Connect" : "Replace Key and Connect")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(prompt.previousFingerprint == nil ? .accentColor : .red)
                Button { decide(false) } label: { Text("Cancel").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.bordered)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
