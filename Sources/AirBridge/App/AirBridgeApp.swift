import SwiftUI

@main
struct AirBridgeApp: App {
    var body: some Scene {
        MenuBarExtra("AirBridge", systemImage: "airplayaudio") {
            Text("AirBridge is running")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
