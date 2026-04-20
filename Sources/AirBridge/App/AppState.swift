import Foundation
import Hummingbird
import SwiftUI
import os

@MainActor
final class AppState: ObservableObject {
    @Published var playbackState: PlaybackState = .idle
    @Published var queueState: QueueState = QueueState()
    @Published var airplayDevices: [AirPlayDevice] = []
    @Published var selectedDevice: AirPlayDevice?

    @Published var listenAddress: String
    @Published var serverPort: Int
    @Published var authToken: String
    @Published var serverRunning: Bool = false

    let engine = PlaybackEngine()
    let queue: PlaybackQueue
    let discovery = BonjourDiscovery()
    private var serverTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?

    init() {
        self.listenAddress = UserDefaults.standard.string(forKey: "listenAddress") ?? "127.0.0.1"
        let portStr = UserDefaults.standard.string(forKey: "serverPort") ?? "9876"
        self.serverPort = Int(portStr) ?? 9876
        self.authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""

        self.queue = PlaybackQueue(engine: engine)

        // State callback from playback engine → SwiftUI
        Task {
            await engine.setStateCallback { [weak self] newState in
                Task { @MainActor in
                    self?.playbackState = newState
                }
            }
        }

        // Start Bonjour discovery and consume updates. Also hand the discovery
        // actor to the playback session so it can resolve endpoints at connect time.
        Task { [engine, discovery] in
            await engine.session.attachDiscovery(discovery)
            await discovery.start()
        }
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.discovery.updates()
            for await devices in stream {
                await MainActor.run {
                    self.airplayDevices = devices
                    // Re-apply any previously selected device if it reappears.
                    if let id = self.selectedDevice?.id,
                       let match = devices.first(where: { $0.id == id }) {
                        self.selectedDevice = match
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

        // Restore previously-saved selected device ID (match against current
        // discovery once it populates).
        let savedID = UserDefaults.standard.string(forKey: "selectedAirPlayDeviceID") ?? ""
        if !savedID.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                // Wait a moment for discovery to populate.
                try? await Task.sleep(for: .seconds(2))
                let devices = await MainActor.run { self.airplayDevices }
                if let device = devices.first(where: { $0.id == savedID }) {
                    await self.selectAirPlayDevice(device)
                }
            }
        }

        startServer()
    }

    /// Set the active AirPlay target; passing nil clears selection.
    func selectAirPlayDevice(_ device: AirPlayDevice?) async {
        self.selectedDevice = device
        UserDefaults.standard.set(device?.id ?? "", forKey: "selectedAirPlayDeviceID")
        await engine.setDevice(device)
    }
}

extension AppState {
    func startServer() {
        guard serverTask == nil else { return }
        let engine = self.engine
        let queue = self.queue
        let discovery = self.discovery
        let address = self.listenAddress
        let port = self.serverPort
        let authToken = self.authToken

        self.serverRunning = true
        self.serverTask = Task.detached { [weak self] in
            do {
                let app = try buildApplication(
                    engine: engine,
                    queue: queue,
                    discovery: discovery,
                    appState: nil,
                    address: address,
                    port: port,
                    authToken: authToken
                )
                Log.server.info("Starting server on \(address, privacy: .public):\(port)")
                try await app.run()
            } catch is CancellationError {
                Log.server.info("Server task cancelled")
            } catch {
                Log.server.error("Server failed: \(error)")
            }
            guard let strongSelf = self else { return }
            await MainActor.run {
                strongSelf.serverRunning = false
            }
        }
    }

    func stopServer() async {
        guard let task = serverTask else { return }
        Log.server.info("Stopping server")
        task.cancel()
        _ = await task.value
        serverTask = nil
        serverRunning = false
    }

    func restartServer() async {
        await stopServer()

        self.listenAddress = UserDefaults.standard.string(forKey: "listenAddress") ?? "127.0.0.1"
        let portStr = UserDefaults.standard.string(forKey: "serverPort") ?? "9876"
        self.serverPort = Int(portStr) ?? 9876
        self.authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""

        startServer()
    }
}
