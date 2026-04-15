import CoreAudio
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var playbackState: PlaybackState = .idle
    @Published var currentRoute: String = "System Default"

    let listenAddress: String
    let serverPort: Int
    let authToken: String

    let engine = PlaybackEngine()

    init() {
        let defaults = UserDefaults.standard
        self.listenAddress = defaults.string(forKey: "listenAddress") ?? "127.0.0.1"
        let portString = defaults.string(forKey: "serverPort") ?? "9876"
        self.serverPort = Int(portString) ?? 9876
        self.authToken = defaults.string(forKey: "authToken") ?? ""

        // Apply saved output device as system default on launch
        let devices = AudioDeviceManager.allOutputDevices()
        let savedDeviceID = defaults.integer(forKey: "outputDeviceID")
        if savedDeviceID != 0 {
            _ = AudioDeviceManager.setDefaultOutputDevice(AudioDeviceID(savedDeviceID))
            self.currentRoute = devices.first(where: { $0.id == AudioDeviceID(savedDeviceID) })?.name ?? "System Default"
        } else {
            let defaultID = AudioDeviceManager.getDefaultOutputDeviceID()
            self.currentRoute = devices.first(where: { $0.id == defaultID })?.name ?? "System Default"
        }

        Task {
            await engine.setStateCallback { [weak self] newState in
                Task { @MainActor in
                    self?.playbackState = newState
                }
            }
        }
        startServer()
    }

    func play(path: String) async throws {
        _ = try await engine.play(path: path)
    }

    func stop() async {
        _ = await engine.stop()
    }
}

extension AppState {
    func startServer() {
        let address = self.listenAddress
        let port = self.serverPort
        let token = self.authToken
        Task.detached { [weak self] in
            guard let self else { return }
            let engine = self.engine
            do {
                let app = try buildApplication(engine: engine, appState: self, address: address, port: port, authToken: token)
                Log.server.info("Starting server on \(address):\(port)")
                try await app.runService()
            } catch {
                Log.server.error("Server failed to start: \(error)")
            }
        }
    }
}
