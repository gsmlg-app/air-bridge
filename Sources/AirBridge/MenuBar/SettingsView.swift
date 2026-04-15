import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @AppStorage("listenAddress") private var listenAddress: String = "127.0.0.1"
    @AppStorage("serverPort") private var portString: String = "9876"
    @AppStorage("authToken") private var authToken: String = ""

    var body: some View {
        Form {
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
                Text("Changes require app restart to take effect.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 250)
        .padding()
    }
}
