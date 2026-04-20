import AVFoundation
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @AppStorage("listenAddress") private var listenAddress: String = "127.0.0.1"
    @AppStorage("serverPort") private var portString: String = "9876"
    @AppStorage("authToken") private var authToken: String = ""
    @AppStorage("selectedAirPlayDeviceID") private var selectedDeviceID: String = ""

    var body: some View {
        Form {
            Section("AirPlay Output") {
                if appState.airplayDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Scanning for AirPlay devices…", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundColor(.secondary)
                        Text("HomePods and Apple TVs on your Wi-Fi network should appear here within a few seconds.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(appState.airplayDevices) { device in
                            Toggle(isOn: binding(for: device)) {
                                HStack(spacing: 6) {
                                    Text(device.displayName)
                                    if let model = device.modelID {
                                        Text("(\(model))")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    if device.supportsAirPlay2 {
                                        Text("AirPlay 2")
                                            .font(.caption2)
                                            .padding(.horizontal, 4)
                                            .background(Color.blue.opacity(0.2))
                                            .cornerRadius(3)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                HStack {
                    Text("Selected: \(selectedDeviceDisplayName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(appState.airplayDevices.count) device(s)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Section("Server") {
                TextField("Address", text: $listenAddress)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $portString)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Authentication") {
                HStack {
                    TextField("Auth Token", text: $authToken)
                        .textFieldStyle(.roundedBorder)
                    Button("Generate") {
                        authToken = Self.generateAuthToken()
                    }
                    .help("Generate a new random 32-character token")
                }
                Text("Leave empty to disable authentication")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Circle()
                        .fill(appState.serverRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(appState.serverRunning ? "Server running" : "Server stopped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Restart Server") {
                        Task { await appState.restartServer() }
                    }
                }
                Text("Applies the current address, port, and token.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 520)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var selectedDeviceDisplayName: String {
        if selectedDeviceID.isEmpty { return "(none)" }
        return appState.airplayDevices.first { $0.id == selectedDeviceID }?.displayName ?? selectedDeviceID
    }

    private func binding(for device: AirPlayDevice) -> Binding<Bool> {
        Binding(
            get: { selectedDeviceID == device.id },
            set: { isOn in
                if isOn {
                    selectedDeviceID = device.id
                    Task { await appState.selectAirPlayDevice(device) }
                } else {
                    selectedDeviceID = ""
                    Task { await appState.selectAirPlayDevice(nil) }
                }
            }
        )
    }

    private static func generateAuthToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
