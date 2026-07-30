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

    @State private var host = ""
    @State private var port = "3389"
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var showImporter = false
    @State private var importError: String?

    private func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, let p = UInt16(port.trimmingCharacters(in: .whitespaces)), !username.isEmpty else { return }
        let d = domain.trimmingCharacters(in: .whitespaces)
        let profile = store.upsert(
            RDPProfile(name: h, host: h, port: p, username: username, domain: d.isEmpty ? nil : d),
            password: password)
        store.markUsed(profile)
        onConnect(h, p, username, password, d.isEmpty ? nil : d)
    }

    private func select(_ profile: RDPProfile) {
        host = profile.host
        port = String(profile.port)
        username = profile.username
        domain = profile.domain ?? ""
        password = store.password(for: profile) ?? ""
        store.markUsed(profile)
    }

    private func applyImportedFile(_ url: URL) {
        importError = nil
        guard url.startAccessingSecurityScopedResource() != false || true else { return }
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
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                          || username.isEmpty
                          || UInt16(port.trimmingCharacters(in: .whitespaces)) == nil)
        }
        .onAppear {
            if host.isEmpty, let last = store.lastUsed { select(last) }
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
