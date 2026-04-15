import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @AppStorage("serverPort") private var portString: String = "9876"

    var body: some View {
        Form {
            Section("Server") {
                TextField("Port", text: $portString)
                    .frame(width: 80)
                Text("Requires app restart to take effect")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300, height: 150)
        .padding()
    }
}
