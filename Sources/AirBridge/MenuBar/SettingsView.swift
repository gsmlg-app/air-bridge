import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @AppStorage("listenAddress") private var listenAddress: String = "127.0.0.1"
    @AppStorage("serverPort") private var portString: String = "9876"
    @AppStorage("authToken") private var authToken: String = ""
    @AppStorage("engineOutputDeviceUID") private var savedDeviceUID: String = ""
    @AppStorage("followSystemDefault") private var followSystemDefault: Bool = false

    @State private var outputDevices: [AudioOutputDeviceInfo] = []
    @State private var selectedDeviceUID: String = ""

    var body: some View {
        Form {
            Section("Audio Output") {
                Picker("Output Device", selection: $selectedDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(outputDevices) { device in
                        Text("\(device.name) (\(device.transport.rawValue))")
                            .tag(device.id)
                    }
                }
                .onChange(of: selectedDeviceUID) { _, newUID in
                    savedDeviceUID = newUID
                    if !newUID.isEmpty {
                        Task {
                            do {
                                _ = try await appState.engine.setOutputDevice(uid: newUID)
                                appState.currentOutputUID = newUID
                                appState.currentOutputName = outputDevices.first { $0.id == newUID }?.name ?? "Unknown"
                            } catch {
                                selectedDeviceUID = appState.currentOutputUID
                            }
                        }
                    }
                }

                Toggle("Follow system default", isOn: $followSystemDefault)
                    .help("Automatically re-pin engine when system default changes")

                HStack {
                    RoutePickerWrapper()
                        .frame(width: 30, height: 30)
                    Text("AirPlay / HomePod")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Refresh Devices") { refreshDevices() }

                Text("Use the AirPlay button to discover HomePods. They will then appear in the device list above.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Server") {
                HStack {
                    Text("Address")
                    TextField("Address", text: $listenAddress)
                        .frame(width: 200)
                }
                HStack {
                    Text("Port")
                    TextField("Port", text: $portString)
                        .frame(width: 80)
                }
            }

            Section("Authentication") {
                SecureField("Auth Token", text: $authToken)
                Text("Leave empty to disable authentication")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Server changes require app restart")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 420)
        .onAppear {
            refreshDevices()
            selectedDeviceUID = savedDeviceUID
        }
    }

    private func refreshDevices() {
        outputDevices = AudioDeviceManager.allOutputDevices(engineTargetUID: savedDeviceUID)
    }
}
