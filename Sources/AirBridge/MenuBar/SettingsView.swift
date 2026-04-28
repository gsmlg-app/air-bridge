import AVFoundation
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @AppStorage("listenAddress") private var listenAddress: String = "127.0.0.1"
    @AppStorage("serverPort") private var portString: String = "9876"
    @AppStorage("authToken") private var authToken: String = ""
    @AppStorage("engineOutputDeviceUID") private var selectedOutputUID: String = ""

    var body: some View {
        TabView {
            settingsForm
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }

            apiDocs
                .tabItem {
                    Label("API Docs", systemImage: "doc.text")
                }
        }
        .frame(width: 460, height: 540)
        .onAppear {
            appState.refreshOutputDevices(engineTargetUID: selectedOutputUID.isEmpty ? nil : selectedOutputUID)
        }
    }

    private var settingsForm: some View {
        Form {
            Section("HomePod Output") {
                if let error = appState.musicAirPlayError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if appState.musicAirPlayDevices.isEmpty {
                    Text("No Music AirPlay devices found.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appState.musicAirPlayDevices) { device in
                        Toggle(isOn: musicAirPlayBinding(for: device)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text("\(device.kind) - \(device.available ? "available" : "offline")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!device.available)
                    }
                }

                HStack {
                    Text("\(appState.selectedMusicAirPlayDeviceIDs.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Refresh") {
                        Task { await appState.refreshMusicAirPlayDevices() }
                    }
                    .font(.caption)
                }
            }

            Section("Audio Output") {
                Picker("Play Target", selection: $selectedOutputUID) {
                    Text("System Default").tag("")
                    ForEach(appState.outputDevices.filter { $0.transport != .airplay }) { device in
                        Text("\(device.name) (\(device.transport.rawValue))").tag(device.id)
                    }
                }
                .onChange(of: selectedOutputUID) { _, newValue in
                    Task {
                        do {
                            _ = try await appState.setOutputDevice(uid: newValue.isEmpty ? nil : newValue)
                            if !newValue.isEmpty {
                                selectedOutputUID = newValue
                            }
                        } catch {
                            Log.output.error("Failed to set output device: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                }

                HStack(spacing: 8) {
                    RoutePickerWrapper(player: OutputRoutingPolicy.systemAirPlayRoutePickerPlayer(for: appState.routePickerPlayer)) {
                        selectedOutputUID = ""
                        Task {
                            await appState.clearPinnedOutputForSystemRouting()
                        }
                    }
                        .frame(width: 28, height: 24)
                    Text("System AirPlay picker")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Refresh") {
                        appState.refreshOutputDevices(engineTargetUID: selectedOutputUID.isEmpty ? nil : selectedOutputUID)
                    }
                    .font(.caption)
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
                Text("Leave empty to disable HTTP API authentication")
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
    }

    private var apiDocs: some View {
        let baseURL = APIServiceDocumentation.baseURL(address: listenAddress, port: portString)
        let examples = APIServiceDocumentation.examples(baseURL: baseURL)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL")
                        .font(.headline)
                    codeBlock(baseURL)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Authentication")
                        .font(.headline)
                    Text("When Auth Token is set, add this header to every request.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    codeBlock(#"-H "\#(APIServiceDocumentation.authHeaderExample)""#)
                }

                ForEach(examples) { example in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(example.title)
                            .font(.headline)
                        Text(example.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        codeBlock(example.command)
                    }
                }
            }
            .padding(18)
        }
    }

    private func codeBlock(_ value: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func musicAirPlayBinding(for device: MusicAirPlayDevice) -> Binding<Bool> {
        Binding(
            get: {
                appState.selectedMusicAirPlayDeviceIDs.contains(device.id)
            },
            set: { isSelected in
                if isSelected {
                    selectedOutputUID = ""
                }
                Task {
                    await appState.setMusicAirPlayDevice(id: device.id, selected: isSelected)
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
