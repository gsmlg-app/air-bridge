import AVFoundation
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @AppStorage("listenAddress") private var listenAddress: String = "127.0.0.1"
    @AppStorage("serverPort") private var portString: String = "9876"
    @AppStorage("authToken") private var authToken: String = ""

    var body: some View {
        Form {
            Section("AirPlay Output") {
                if appState.airplayDevices.isEmpty && appState.selectedDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Scanning for AirPlay devices…", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundColor(.secondary)
                        Text("HomePods and Apple TVs on your Wi-Fi network should appear here within a few seconds.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        // Show all Bonjour devices, plus any selected offline ones
                        let allIDs = Set(appState.airplayDevices.map(\.id)).union(appState.selectedDevices.map(\.id))
                        let sortedIDs = Array(allIDs).sorted()

                        ForEach(sortedIDs, id: \.self) { id in
                            let device = appState.airplayDevices.first(where: { $0.id == id }) ?? AirPlayDevice(id: id, displayName: id, serviceType: "", txt: [:])
                            let isSelected = appState.selectedDevices.contains(where: { $0.id == id })
                            let isAtLimit = appState.selectedDevices.count >= 8
                            let unsupportedReason = device.unsupportedTargetReason
                            let isDisabled = !isSelected && (isAtLimit || unsupportedReason != nil)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Toggle(isOn: binding(for: device)) {
                                        HStack {
                                            Text(device.displayName)
                                            if let model = device.modelID {
                                                Text("(\(model))").font(.caption).foregroundColor(.secondary)
                                            }
                                            if device.supportsAirPlay2 {
                                                Text("AirPlay 2").font(.caption2).padding(.horizontal, 4).background(Color.blue.opacity(0.2)).cornerRadius(3)
                                            }
                                            if unsupportedReason != nil {
                                                Text("Unsupported").font(.caption2).padding(.horizontal, 4).background(Color.gray.opacity(0.18)).cornerRadius(3)
                                            }
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .disabled(isDisabled)
                                    .help(unsupportedReason ?? (isDisabled ? "Max 8 devices selected." : ""))

                                    Spacer()

                                    // Status Badge
                                    if let sel = appState.selectedDevices.first(where: { $0.id == id }) {
                                        switch sel.status {
                                        case .ok:
                                            Text("● ok").foregroundColor(.green).font(.caption)
                                        case .pairing:
                                            Text("◐ pairing").foregroundColor(.yellow).font(.caption)
                                        case .offline:
                                            Text("○ offline").foregroundColor(.gray).font(.caption)
                                        case .error:
                                            Text("⚠ error").foregroundColor(.red).font(.caption)
                                        }
                                    }
                                }

                                // Error Details & Retry
                                if let sel = appState.selectedDevices.first(where: { $0.id == id }), case .error(let reason) = sel.status {
                                    HStack {
                                        Text("└ \(reason)").font(.caption).foregroundColor(.secondary)
                                        if device.isSupportedTarget {
                                            Button("Retry") {
                                                Task { await appState.engine.retry(deviceID: id) }
                                            }
                                            .buttonStyle(.borderless)
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                        }
                                    }
                                    .padding(.leading, 24)
                                } else if let unsupportedReason {
                                    Text("└ \(unsupportedReason)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 24)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Text("\(appState.selectedDevices.count) of 8 selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(appState.airplayDevices.count) device(s) found")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    RoutePickerWrapper()
                        .frame(width: 28, height: 24)
                    Text("System AirPlay picker")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
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
        .frame(width: 420, height: 560)
    }

    private func binding(for device: AirPlayDevice) -> Binding<Bool> {
        Binding(
            get: { appState.selectedDevices.contains(where: { $0.id == device.id }) },
            set: { _ in
                Task { await appState.toggleSelection(device) }
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
