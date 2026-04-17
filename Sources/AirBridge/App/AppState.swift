import CoreAudio
import Foundation
import Hummingbird
import SwiftUI
import os

@MainActor
final class AppState: ObservableObject {
    @Published var playbackState: PlaybackState = .idle
    @Published var queueState: QueueState = QueueState()
    @Published var currentOutputName: String = "System Default"
    @Published var currentOutputUID: String = ""

    let listenAddress: String
    let serverPort: Int
    let authToken: String

    let engine = PlaybackEngine()
    let queue: PlaybackQueue
    private var deviceObserver: OutputDeviceObserver?

    init() {
        // Migrate v1 settings if needed
        Self.migrateV1Settings()

        self.listenAddress = UserDefaults.standard.string(forKey: "listenAddress") ?? "127.0.0.1"
        let portStr = UserDefaults.standard.string(forKey: "serverPort") ?? "9876"
        self.serverPort = Int(portStr) ?? 9876
        self.authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""

        self.queue = PlaybackQueue(engine: engine)

        // Restore saved output device
        let savedUID = UserDefaults.standard.string(forKey: "engineOutputDeviceUID") ?? ""
        if !savedUID.isEmpty {
            self.currentOutputUID = savedUID
            Task {
                do {
                    _ = try await engine.setOutputDevice(uid: savedUID)
                    let devices = AudioDeviceManager.allOutputDevices(engineTargetUID: savedUID)
                    if let dev = devices.first(where: { $0.id == savedUID }) {
                        self.currentOutputName = dev.name
                    }
                } catch {
                    Log.output.error("Failed to restore output device \(savedUID, privacy: .public): \(error)")
                }
            }
        }

        // State callback
        Task {
            await engine.setStateCallback { [weak self] newState in
                Task { @MainActor in
                    self?.playbackState = newState
                }
            }
        }

        // Device observer
        let followDefault = UserDefaults.standard.bool(forKey: "followSystemDefault")
        self.deviceObserver = OutputDeviceObserver { [weak self] newDefaultID in
            Task { @MainActor in
                guard let self else { return }
                if followDefault {
                    if let uid = AudioDeviceManager.deviceUID(for: newDefaultID) {
                        do {
                            _ = try await self.engine.setOutputDevice(uid: uid)
                            self.currentOutputUID = uid
                            self.currentOutputName = AudioDeviceManager.allOutputDevices().first { $0.isSystemDefault }?.name ?? "Unknown"
                            UserDefaults.standard.set(uid, forKey: "engineOutputDeviceUID")
                        } catch {
                            Log.output.error("Failed to follow system default: \(error)")
                        }
                    }
                }
            }
        }

        // Periodic queue state sync
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let q = await queue.list()
                self.queueState = q
            }
        }

        startServer()
    }

    private static func migrateV1Settings() {
        let defaults = UserDefaults.standard
        if let oldID = defaults.object(forKey: "outputDeviceID") as? Int, oldID != 0 {
            let deviceID = AudioDeviceID(oldID)
            if let uid = AudioDeviceManager.deviceUID(for: deviceID) {
                defaults.set(uid, forKey: "engineOutputDeviceUID")
                Log.output.info("Migrated v1 outputDeviceID \(oldID) → UID \(uid, privacy: .public)")
            }
            defaults.removeObject(forKey: "outputDeviceID")
        }
    }
}

extension AppState {
    func startServer() {
        let engine = self.engine
        let queue = self.queue
        let address = self.listenAddress
        let port = self.serverPort
        let authToken = self.authToken

        Task.detached {
            do {
                let app = try buildApplication(
                    engine: engine,
                    queue: queue,
                    appState: nil,
                    address: address,
                    port: port,
                    authToken: authToken
                )
                Log.server.info("Starting server on \(address, privacy: .public):\(port)")
                try await app.run()
            } catch {
                Log.server.error("Server failed: \(error)")
            }
        }
    }
}
