import SwiftUI
import AVFoundation

// Shared iOS UI/state used by both targets (ClamshellViewer iPad + Clamshell
// ControlApp iPhone): saved-machine profiles, the QR pairing scanner, and the
// connection-quality indicator. Compiled into both targets.

// MARK: - Saved machine profiles

/// One saved Mac. Persisted as JSON in UserDefaults; each app keeps its own
/// list (separate bundle IDs = separate defaults), so a phone and an iPad can
/// hold different display-index preferences for the same Mac.
struct MachineProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var displayIndex: Int = 0
}

enum ContentViewNaming {
    /// A readable saved-machine name derived from an address: the host of a
    /// URL, or the raw address (first segment before a "|" Display-B split).
    static func deriveName(_ host: String) -> String {
        if let c = URLComponents(string: host), let h = c.host { return h }
        return host.split(separator: "|").first.map(String.init) ?? host
    }
}

final class MachineStore: ObservableObject {
    @Published private(set) var machines: [MachineProfile] = []
    /// Host of the machine connected to most recently — used to pre-select the
    /// connect form on launch so it isn't a blank field every time.
    @Published private(set) var lastUsedHost: String?
    private let key = "savedMachines"
    private let lastUsedKey = "lastUsedHost"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([MachineProfile].self, from: data) {
            machines = list
        }
        lastUsedHost = UserDefaults.standard.string(forKey: lastUsedKey)
    }

    /// The saved profile last connected to, if it still exists.
    var lastUsed: MachineProfile? {
        guard let h = lastUsedHost else { return nil }
        return machines.first { $0.host == h }
    }

    /// Record which machine was just connected to (call on every connect).
    func markUsed(_ host: String) {
        lastUsedHost = host
        UserDefaults.standard.set(host, forKey: lastUsedKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(machines) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Adds or updates by host (a re-scan of the same Mac refreshes its token
    /// rather than piling up duplicates), keeping the given name.
    func upsert(_ machine: MachineProfile) {
        if let idx = machines.firstIndex(where: { $0.host == machine.host }) {
            var updated = machine
            updated.id = machines[idx].id
            machines[idx] = updated
        } else {
            machines.append(machine)
        }
        persist()
    }

    func delete(_ machine: MachineProfile) {
        machines.removeAll { $0.id == machine.id }
        persist()
    }
}

// MARK: - Connection quality indicator

/// Unobtrusive stream-quality dot, sitting alongside the software-encoding
/// banner. Green near the bitrate ceiling, yellow reduced, orange near the
/// floor. "Nerd Mode" (opt-in, off by default) expands it into a one-line
/// readout. Shows nothing until the host has reported a bitrate.
struct QualityIndicator: View {
    @ObservedObject var client: StreamClient
    @AppStorage("nerdMode") private var nerdMode = false

    private var kbps: Int { Int(client.currentBitrateKbps) }

    // Thresholds relative to the 20 Mbps ceiling / 2 Mbps floor (PROTOCOL.md).
    private var color: Color {
        switch kbps {
        case 15000...: return .green
        case 6000..<15000: return .yellow
        default: return .orange
        }
    }

    private var detail: String {
        let mbps = String(format: "%.1f", Double(kbps) / 1000)
        let res = client.videoSize == .zero ? "" : " · \(Int(client.videoSize.width))×\(Int(client.videoSize.height))"
        let hw = client.softwareEncoding ? "SW" : "HW"
        return "\(client.codecName)\(res) · \(hw) · \(mbps) Mbps"
    }

    var body: some View {
        if client.currentBitrateKbps > 0 {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                if nerdMode {
                    Text(detail).font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            // Tap the dot to expand/collapse the stats readout live, no reconnect.
            .contentShape(Capsule())
            .onTapGesture { nerdMode.toggle() }
        }
    }
}

// MARK: - QR pairing scanner

/// Full-screen camera QR scanner (AVCaptureMetadataOutput — no third-party
/// library). Calls `onScan` with the first decoded string, once.
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> QRScannerController {
        let vc = QRScannerController()
        vc.onScan = { context.coordinator.deliver($0) }
        vc.onCancel = onCancel
        return vc
    }
    func updateUIViewController(_ vc: QRScannerController, context: Context) {}

    final class Coordinator {
        private let parent: QRScannerView
        private var delivered = false
        init(_ parent: QRScannerView) { self.parent = parent }
        func deliver(_ code: String) {
            guard !delivered else { return }
            delivered = true
            parent.onScan(code)
        }
    }
}

final class QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { showFailure(); return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { showFailure(); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        self.preview = preview

        let hint = UILabel()
        hint.text = "Point at the Clamshell QR code on your Mac"
        hint.textColor = .white
        hint.textAlignment = .center
        hint.font = .systemFont(ofSize: 15, weight: .medium)
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -80),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
              let string = obj.stringValue else { return }
        session.stopRunning()
        onScan?(string)
    }

    @objc private func cancelTapped() { onCancel?() }

    private func showFailure() {
        let label = UILabel()
        label.text = "Camera unavailable"
        label.textColor = .white
        label.textAlignment = .center
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
}

// MARK: - Saved-machines picker (connect-screen section)

/// Compact list of saved Macs with select + delete, shown above the manual
/// connect fields. Selecting one calls `onSelect`.
struct SavedMachinesView: View {
    @ObservedObject var store: MachineStore
    var onSelect: (MachineProfile) -> Void
    /// Host to visually mark as pre-selected (the last-used machine).
    var selectedHost: String? = nil

    var body: some View {
        if !store.machines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved Machines").font(.footnote).foregroundStyle(.gray)
                ForEach(store.machines) { machine in
                    let isSelected = machine.host == selectedHost
                    HStack {
                        Button { onSelect(machine) } label: {
                            HStack(spacing: 8) {
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(machine.name).foregroundStyle(.white)
                                    Text(machine.host).font(.caption2).foregroundStyle(.gray)
                                }
                            }
                        }
                        Spacer()
                        Button(role: .destructive) { store.delete(machine) } label: {
                            Image(systemName: "trash").foregroundStyle(.red.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(isSelected ? .green.opacity(0.14) : .white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: 420)
        }
    }
}

// MARK: - In-session settings (reachable mid-stream, both apps)

/// Lightweight sheet presented from the streaming view: flip Nerd Mode live
/// (shared @AppStorage — takes effect immediately, no reconnect) and switch to
/// another saved machine (which disconnects + reconnects). Deliberately minimal.
struct InSessionSettingsView: View {
    @ObservedObject var store: MachineStore
    /// Host of the machine currently streaming, marked with a checkmark.
    var currentHost: String
    /// Called when the user picks a different machine — caller disconnects and
    /// reconnects to it.
    var onSwitch: (MachineProfile) -> Void
    var onClose: () -> Void
    @AppStorage("nerdMode") private var nerdMode = false

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Nerd Mode (show stream stats)", isOn: $nerdMode)
                if !store.machines.isEmpty {
                    Section("Switch machine (reconnects)") {
                        ForEach(store.machines) { m in
                            Button { onSwitch(m) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.name)
                                        Text(m.host).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if m.host == currentHost {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Session Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
        }
    }
}
