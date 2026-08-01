import SwiftUI
import UniformTypeIdentifiers

// RDP connection UI: manual host/port/user/pass entry, or import a `.rdp`
// file (parsed by RDPFileParser — never the password, see that file's
// header comment). Saved targets follow SavedMachinesView's shape. Kept in
// its own file/view rather than folded into ContentView's connectForm so
// the Clamshell-protocol path in ViewerApp.swift stays untouched.

struct RDPConnectForm: View {
    @ObservedObject var store: RDPProfileStore
    var onConnect: (_ host: String, _ port: UInt16, _ username: String, _ password: String, _ domain: String?) -> Void
    /// Whether the manual-entry fields + Connect button are shown. The saved
    /// targets list above them is always shown regardless — ContentView now
    /// displays Clamshell and RDP saved lists together, gating only the
    /// new-connection fields behind its per-entry protocol picker.
    var showManualFields: Bool = true
    /// Selecting a saved profile while `showManualFields` is false fills the
    /// fields as before, but they'd be invisible — this tells the parent to
    /// flip its protocol picker to RDP so the filled fields (and Connect) show.
    var onSelectedProfileNeedsManual: (() -> Void)? = nil

    @State private var host = ""
    @State private var port = "3389"
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var showImporter = false
    @State private var importError: String?

    /// Single source of truth for "is this form fillable enough to connect" —
    /// used by both the Connect button's `disabled` state and `connect()`'s
    /// guard, so they can't drift apart (previously two separate trim/parse
    /// implementations could disagree, leaving the button enabled while
    /// connect() silently no-op'd).
    private var validatedPort: UInt16? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, !username.isEmpty else { return nil }
        return UInt16(port.trimmingCharacters(in: .whitespaces))
    }

    private func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard let p = validatedPort else {
            importError = "Enter a valid host, port, and username before connecting."
            return
        }
        let d = domain.trimmingCharacters(in: .whitespaces)
        let profile = store.upsert(
            RDPProfile(name: h, host: h, port: p, username: username, domain: d.isEmpty ? nil : d),
            password: password)
        store.markUsed(profile)
        onConnect(h, p, username, password, d.isEmpty ? nil : d)
    }

    /// `notifyParent: false` is used for the silent on-appear preload, which
    /// must not flip the parent's protocol picker just because a saved RDP
    /// profile happens to exist — only an explicit tap on a saved target should.
    private func select(_ profile: RDPProfile, notifyParent: Bool = true) {
        host = profile.host
        port = String(profile.port)
        username = profile.username
        domain = profile.domain ?? ""
        password = store.password(for: profile) ?? ""
        store.markUsed(profile)
        if notifyParent, !showManualFields { onSelectedProfileNeedsManual?() }
    }

    private func applyImportedFile(_ url: URL) {
        importError = nil
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let info = RDPFileParser.parse(text) else {
            importError = "Couldn't read that .rdp file."
            return
        }
        host = info.host
        port = String(info.port)
        if let u = info.username { username = u }
        if let d = info.domain { domain = d }
        // Password is intentionally never read from the file — see
        // RDPFile.swift. The user still needs to type it once here.
    }

    var body: some View {
        VStack(spacing: 16) {
            if !store.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saved RDP Targets").font(.footnote).foregroundStyle(.gray)
                    ForEach(store.profiles) { profile in
                        HStack {
                            Button { select(profile) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).foregroundStyle(.white)
                                    Text("\(profile.username)@\(profile.host):\(profile.port)")
                                        .font(.caption2).foregroundStyle(.gray)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) { store.delete(profile) } label: {
                                Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .frame(maxWidth: 420)
            }

            if showManualFields {
                Button { showImporter = true } label: {
                    Label("Import .rdp File", systemImage: "doc.badge.arrow.up")
                }
                .buttonStyle(.bordered)
                if let importError {
                    Text(importError).font(.caption2).foregroundStyle(.red)
                }

                Group {
                    TextField("Host or IP", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Port", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Domain (optional)", text: $domain)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: 420)

                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .disabled(validatedPort == nil)
            }
        }
        .onAppear {
            if host.isEmpty, let last = store.lastUsed { select(last, notifyParent: false) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { applyImportedFile(url) }
        }
    }
}

/// Shown while an RDP session is connecting/streaming: the framebuffer (or
/// a spinner/error before the first frame) plus a disconnect control, same
/// visual shape as ContentView's Clamshell-protocol overlay.
struct RDPStreamView: View {
    @ObservedObject var session: RDPSession
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case .streaming = session.status {
                RDPView(session: session).ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    if case .failed(let reason) = session.status {
                        Text(reason).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding()
        }
    }
}

/// Alert-based certificate trust prompt, wired to RDPSession.onCertificatePrompt.
struct RDPCertificatePrompt: ViewModifier {
    @Binding var pending: (subject: String, issuer: String, fingerprint: String, completion: (Bool) -> Void)?

    func body(content: Content) -> some View {
        content.alert("Untrusted Certificate", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending?.completion(false); pending = nil } }
        )) {
            Button("Cancel", role: .cancel) { pending?.completion(false); pending = nil }
            Button("Trust") { pending?.completion(true); pending = nil }
        } message: {
            if let pending {
                Text("Subject: \(pending.subject)\nIssuer: \(pending.issuer)\nFingerprint: \(pending.fingerprint)")
            }
        }
    }
}
