import SwiftUI

// The screens for the connection flow's questions and refusals. Plain SwiftUI
// on purpose: a design pass restyles the whole app later, so the wording is
// what matters here. It sits over the connect form and the stream in both the
// iPad and iPhone UIs and shows nothing unless `client.authState` asks for it.

struct AuthPromptView: View {
    @ObservedObject var client: StreamClient

    var body: some View {
        switch client.authState {
        case let .waitingForApproval(hostName, hostFingerprint, deviceName, deviceFingerprint)?:
            card(title: "Waiting for approval",
                 text: "On \(hostName), open Clamshell in the menu bar and approve this device. Check that the Mac shows the same fingerprint for it.",
                 rows: ["This device: \(deviceName), \(deviceFingerprint)",
                        "The Mac: \(hostName), \(hostFingerprint)"],
                 buttons: [("Cancel", true, { client.disconnect() })])
        case let .confirmHost(hostName, fingerprint)?:
            card(title: "Is this your Mac?",
                 text: "\(hostName) let this device in without asking. Before you connect, check that this fingerprint matches the one under Devices in Clamshell's menu on the Mac.",
                 rows: [fingerprint],
                 buttons: [("Connect", false, { client.answerAuthQuestion(true) }),
                           ("Cancel", true, { client.answerAuthQuestion(false) })])
        case let .changedIdentity(address, saved, now)?:
            card(title: "This Mac's identity has changed",
                 text: "The computer at \(address) is not the one this app saved. Clamshell may have been set up again on it, it may be a different computer, or someone may be in the way of the connection. Nothing was sent to it.",
                 rows: ["Saved: \(saved)", "Now showing: \(now)"],
                 buttons: [("Close", true, { client.disconnect() })])
        case let .didNotIdentify(hostName)?:
            card(title: "This Mac did not identify itself",
                 text: "\(hostName) has always proved who it is before, and this time it did not. Nothing was sent to it.",
                 rows: [],
                 buttons: [("Close", true, { client.disconnect() })])
        case let .askUnverified(address)?:
            card(title: "This Mac can't prove who it is",
                 text: "It may be running a version of Clamshell older than 0.12. Whatever you type goes to the computer that answers at \(address). Connect anyway?",
                 rows: [],
                 buttons: [("Connect", false, { client.answerAuthQuestion(true) }),
                           ("Cancel", true, { client.answerAuthQuestion(false) })])
        case let .denied(hostName)?:
            card(title: "This Mac turned this device away",
                 text: "It was denied or revoked on \(hostName). It can be allowed again under Devices in Clamshell's menu on the Mac.",
                 rows: [],
                 buttons: [("Close", true, { client.disconnect() })])
        case let .invalid(hostName)?:
            card(title: "This Mac did not accept this device",
                 text: "\(hostName) could not accept this device's request. Nothing more was sent.",
                 rows: [],
                 buttons: [("Close", true, { client.disconnect() })])
        case let .hostNeedsKeychain(retryIn)?:
            card(title: "The Mac needs Keychain approval",
                 text: "The Mac needs Keychain approval for Clamshell before it can accept devices. Approve it on the Mac. Trying again in \(retryIn) s.",
                 rows: [],
                 buttons: [("Cancel", true, { client.disconnect() })])
        case let .remoteAccessOff(retryIn)?:
            card(title: "Remote access is off",
                 text: "Remote access is switched off in Clamshell on this Mac. Turn it on from Clamshell's menu there. Trying again in \(retryIn) s.",
                 rows: [],
                 buttons: [("Cancel", true, { client.disconnect() })])
        case let .busy(retryIn)?:
            card(title: "The Mac is busy",
                 text: "The Mac is busy. Trying again in \(retryIn) s.",
                 rows: [],
                 buttons: [("Cancel", true, { client.disconnect() })])
        case let .connected(verified, _)?:
            if !verified {
                // Stays visible for as long as this unverified session runs.
                VStack {
                    HStack {
                        Text("Not verified")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.orange, in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
                .allowsHitTesting(false)
            }
        case .connecting?, .failed?, nil:
            EmptyView()
        }
    }

    /// One dialog: title, text, optional rows of values, and buttons given as
    /// (label, is cancel-like, action).
    private func card(title: String, text: String, rows: [String],
                      buttons: [(String, Bool, () -> Void)]) -> some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title3.weight(.semibold))
                Text(text).font(.body)
                ForEach(rows, id: \.self) { row in
                    Text(row).font(.callout.monospaced()).textSelection(.enabled)
                }
                HStack {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                        if button.1 {
                            Button(button.0, role: .cancel, action: button.2).buttonStyle(.bordered)
                        } else {
                            Button(button.0, action: button.2).buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(16)
        }
    }
}
