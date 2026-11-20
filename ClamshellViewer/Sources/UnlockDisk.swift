import SwiftUI
import Security
import LocalAuthentication

/// The saved FileVault account used by "Unlock disk" and "Restart Mac". Keychain item behind
/// Face ID or Touch ID for the current set of enrolled fingers or faces, this device only,
/// only while a passcode is set. Transport-agnostic: it only stores and returns the account.
enum UnlockCredentialStore {
    private static let service = "com.frindle.clamshell.viewer.unlock"
    private static let account = "filevault-account"

    struct Account { var username: String; var password: String }

    static var hasSaved: Bool {
        let ctx = LAContext(); ctx.interactionNotAllowed = true
        var q = baseQuery(); q[kSecUseAuthenticationContext as String] = ctx
        let s = SecItemCopyMatching(q as CFDictionary, nil)
        return s == errSecSuccess || s == errSecInteractionNotAllowed
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    @discardableResult
    static func save(username: String, password: String) -> Bool {
        guard let json = try? JSONSerialization.data(withJSONObject: ["u": username, "p": password]),
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil)
        else { return false }
        SecItemDelete(baseQuery() as CFDictionary)
        var q = baseQuery()
        q[kSecValueData as String] = json
        q[kSecAttrAccessControl as String] = access
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    /// Shows the Face ID prompt with `reason`.
    static func load(reason: String) -> Account? {
        let ctx = LAContext(); ctx.localizedReason = reason
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = ctx
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let u = obj["u"], let p = obj["p"] else { return nil }
        return Account(username: u, password: p)
    }

    static func forget() { SecItemDelete(baseQuery() as CFDictionary) }
}

/// Host keys the user accepted, by "host:port" (a fingerprint is public, so UserDefaults is fine).
enum SSHPinStore {
    private static let key = "unlockSSHHostKeys"
    static func load() -> SSHHostPins { SSHHostPins(UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]) }
    static func save(_ pins: SSHHostPins) { UserDefaults.standard.set(pins.pins, forKey: key) }
}

/// "Unlock disk": SSH straight to the Mac's pre-boot sshd. Never logs the account.
@MainActor
final class DiskUnlockModel: ObservableObject {
    @Published var message = ""
    @Published var busy = false
    @Published var askFingerprint: String?
    private var answer: CheckedContinuation<Bool, Never>?

    func unlock(host: String, username: String, password: String) {
        guard !busy, !host.isEmpty else { return }
        busy = true; message = "Connecting…"
        let unlocker = DiskUnlocker(
            transport: NIOSSHUnlockTransport(),
            loadPins: { SSHPinStore.load() }, savePins: { SSHPinStore.save($0) },
            askToTrust: { [weak self] _, fp in await self?.ask(fp) ?? false })
        Task {
            let result = await unlocker.unlock(host: host, username: username, password: password)
            message = result.text; busy = false
        }
    }

    private func ask(_ fingerprint: String) async -> Bool {
        await withCheckedContinuation { c in answer = c; askFingerprint = fingerprint }
    }
    func respond(_ yes: Bool) { askFingerprint = nil; answer?.resume(returning: yes); answer = nil }
}

struct UnlockDiskSection: View {
    @AppStorage("hostAddress") private var address = ""
    @StateObject private var model = DiskUnlockModel()
    @State private var open = false
    @State private var user = ""
    @State private var pass = ""
    @State private var save = true

    private var host: String { ContentViewNaming.deriveName(address.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        VStack(spacing: 8) {
            Button("Unlock disk…") { open.toggle() }
                .font(.footnote).buttonStyle(.bordered).tint(.white)
            if open {
                Text("After a power cut the Mac waits for its disk to be unlocked. This signs in to the Mac over SSH with an account that can unlock it, then reconnects.")
                    .font(.caption).foregroundStyle(.gray).multilineTextAlignment(.center)
                if UnlockCredentialStore.hasSaved {
                    Button("Unlock with saved account") {
                        if let a = UnlockCredentialStore.load(reason: "Unlock the Mac's disk") {
                            model.unlock(host: host, username: a.username, password: a.password)
                        }
                    }.buttonStyle(.borderedProminent).disabled(model.busy)
                    Button("Forget saved account") { UnlockCredentialStore.forget() }.font(.caption)
                } else {
                    TextField("Mac user name", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    SecureField("Password", text: $pass).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    Toggle("Save on this device (Face ID)", isOn: $save).frame(maxWidth: 320).font(.footnote)
                    Button("Unlock") {
                        let u = user, p = pass
                        if save { UnlockCredentialStore.save(username: u, password: p) }
                        pass = ""
                        model.unlock(host: host, username: u, password: p)
                    }.buttonStyle(.borderedProminent).disabled(model.busy || user.isEmpty || pass.isEmpty)
                }
                if !model.message.isEmpty { Text(model.message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
            }
        }
        .alert("Trust this Mac?", isPresented: Binding(get: { model.askFingerprint != nil }, set: { _ in }), presenting: model.askFingerprint) { _ in
            Button("Trust") { model.respond(true) }
            Button("Cancel", role: .cancel) { model.respond(false) }
        } message: { fp in
            Text("First time unlocking this Mac. Check that its SSH key fingerprint is:\n\(fp)\nIt is remembered, and a different key later is refused.")
        }
    }
}

/// Restart the Mac with `fdesetup authrestart` (skips the disk unlock once). The account goes
/// inside the encrypted stream for this one call and is not kept by the Mac.
struct RestartMacSheet: View {
    @ObservedObject var client: StreamClient
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var pass = ""
    @State private var message = ""
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                Text("Restarts the Mac now and skips the disk unlock screen once.").font(.footnote)
                if UnlockCredentialStore.hasSaved {
                    Button("Restart with saved account") {
                        if let a = UnlockCredentialStore.load(reason: "Restart the Mac") { go(a.username, a.password) }
                    }
                } else {
                    TextField("Mac user name", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $pass)
                    Button("Restart") { let u = user, p = pass; pass = ""; go(u, p) }.disabled(user.isEmpty || pass.isEmpty || sent)
                }
                if !message.isEmpty { Text(message).font(.footnote) }
            }
            .navigationTitle("Restart Mac")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear {
            client.onRestartResult = { code in
                switch code {
                case 0: message = "Restarting. The disk will not ask to be unlocked this time."
                case 1: message = "The Mac did not accept that user name and password."; sent = false
                case 2: message = "This Mac cannot do an authenticated restart."; sent = false
                default: message = "Could not start the restart."; sent = false
                }
            }
        }
    }

    private func go(_ u: String, _ p: String) {
        sent = true; message = "Sent. Waiting for the Mac…"
        client.sendRestart(username: u, password: p)
    }
}
