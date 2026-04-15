import SwiftUI
import AVKit

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @AppStorage("listenAddress") private var listenAddress: String = "127.0.0.1"
    @AppStorage("serverPort") private var portString: String = "9876"
    @AppStorage("authToken") private var authToken: String = ""
    @AppStorage("outputDeviceID") private var savedDeviceID: Int = 0

    @State private var outputDevices: [AudioOutputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0

    var body: some View {
        Form {
            Section("Audio Output") {
                Picker("Play Target", selection: $selectedDeviceID) {
                    Text("System Default").tag(AudioDeviceID(0))
                    ForEach(outputDevices) { device in
                        Text("\(device.name) (\(device.transportLabel))")
                            .tag(device.id)
                    }
                }
                .onChange(of: selectedDeviceID) { _, newValue in
                    savedDeviceID = Int(newValue)
                    // Update engine output device for next playback
                    Task {
                        await appState.engine.setOutputDevice(newValue)
                    }
                    // Update route display
                    if newValue != 0 {
                        appState.currentRoute = outputDevices.first(where: { $0.id == newValue })?.name ?? "System Default"
                    } else {
                        let defaultID = AudioDeviceManager.getDefaultOutputDeviceID()
                        appState.currentRoute = outputDevices.first(where: { $0.id == defaultID })?.name ?? "System Default"
                    }
                }

                HStack {
                    Text("AirPlay Devices:")
                        .font(.caption)
                    RoutePickerWrapper()
                        .frame(width: 24, height: 24)
                    Text("Click to discover AirPlay targets")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Refresh Devices") {
                    refreshDevices()
                }
                .font(.caption)
            }

            Section("Server") {
                TextField("Listen Address", text: $listenAddress)
                    .frame(width: 200)
                TextField("Port", text: $portString)
                    .frame(width: 80)
            }

            Section("Authentication") {
                SecureField("Auth Token", text: $authToken)
                    .frame(width: 200)
                Text("Leave empty to disable authentication.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Text("Server changes require app restart to take effect.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 380)
        .padding()
        .onAppear {
            refreshDevices()
            selectedDeviceID = AudioDeviceID(savedDeviceID)
        }
    }

    private func refreshDevices() {
        outputDevices = AudioDeviceManager.allOutputDevices()
        if selectedDeviceID != 0 {
            appState.currentRoute = outputDevices.first(where: { $0.id == selectedDeviceID })?.name ?? "System Default"
        } else {
            let currentDefault = AudioDeviceManager.getDefaultOutputDeviceID()
            appState.currentRoute = outputDevices.first(where: { $0.id == currentDefault })?.name ?? "System Default"
        }
    }
}
