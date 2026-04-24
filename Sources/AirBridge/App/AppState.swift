import Foundation
import Hummingbird
import SwiftUI
import os

@MainActor
final class AppState: ObservableObject {
    @Published var playbackState: PlaybackState = .idle
    @Published var queueState: QueueState = QueueState()
    @Published var airplayDevices: [AirPlayDevice] = []
    @Published var selectedDevices: [SelectedDevice] = []

    @Published var listenAddress: String
    @Published var serverPort: Int
    @Published var authToken: String
    @Published var serverRunning: Bool = false

    let engine = PlaybackEngine()
    let queue: PlaybackQueue
    let discovery = BonjourDiscovery()
    let advertiser = ServiceAdvertiser()
    private var serverTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?

    init() {
        self.listenAddress = UserDefaults.standard.string(forKey: "listenAddress") ?? "127.0.0.1"
        let portStr = UserDefaults.standard.string(forKey: "serverPort") ?? "9876"
        self.serverPort = Int(portStr) ?? 9876
        self.authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""

        self.queue = PlaybackQueue(engine: engine)

        // Status callback from playback engine (multi-device) → SwiftUI
        Task {
            await engine.setStatusCallback { [weak self] devices in
                Task { @MainActor in
                    self?.selectedDevices = devices
                }
            }
        }

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
            await engine.attachDiscovery(discovery)
            await discovery.start()
        }

        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.discovery.updates()
            for await devices in stream {
                await MainActor.run {
                    self.airplayDevices = devices
                }

                // Handle offline/retry
                let currentSelected = await self.engine.selectedDevices()
                for sel in currentSelected {
                    let inBonjour = devices.contains(where: { $0.id == sel.id })
                    if !inBonjour && sel.status != .offline {
                        await self.engine.markOffline(deviceID: sel.id)
                    } else if inBonjour && sel.status == .offline {
                        await self.engine.retry(deviceID: sel.id)
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

        // Restore previously-saved devices
        let savedIDs: [String]
        if let data = UserDefaults.standard.data(forKey: "selectedAirPlayDeviceIDs"),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            savedIDs = decoded
        } else if let legacyID = UserDefaults.standard.string(forKey: "selectedAirPlayDeviceID"), !legacyID.isEmpty {
            savedIDs = [legacyID]
            let data = try? JSONEncoder().encode(savedIDs)
            UserDefaults.standard.set(data, forKey: "selectedAirPlayDeviceIDs")
            UserDefaults.standard.removeObject(forKey: "selectedAirPlayDeviceID")
        } else {
            savedIDs = []
        }

        if !savedIDs.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                // Seed offline devices immediately so UI shows them
                let offlineDevices = savedIDs.map { id in
                    AirPlayDevice(id: id, displayName: id, serviceType: "_airplay._tcp.", txt: [:])
                }
                await self.engine.setSelectedDevices(offlineDevices)
                for id in savedIDs {
                    await self.engine.markOffline(deviceID: id)
                }

                try? await Task.sleep(for: .seconds(2))
                let devices = await MainActor.run { self.airplayDevices }
                let toSelect = savedIDs.compactMap { id in devices.first(where: { $0.id == id }) }
                if !toSelect.isEmpty {
                    await self.engine.setSelectedDevices(toSelect)
                }
            }
        }

        startServer()
    }
    /// Replaces the entire selection based on HTTP API requests.
    func setSelectedDevices(_ ids: [String]) async {
        let devices = await MainActor.run { self.airplayDevices }
        var resolved: [AirPlayDevice] = []
        for id in ids {
            if let d = devices.first(where: { $0.id == id }) {
                resolved.append(d)
            } else {
                // Unknown to Bonjour right now, construct a stub to track offline
                resolved.append(AirPlayDevice(id: id, displayName: id, serviceType: "_airplay._tcp.", txt: [:]))
            }
        }
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: "selectedAirPlayDeviceIDs")
        }
        await engine.setSelectedDevices(resolved)

        // Mark unknown ones offline immediately
        for id in ids {
            if !devices.contains(where: { $0.id == id }) {
                await engine.markOffline(deviceID: id)
            }
        }
    }

    /// Toggles a single device for the Settings UI checkboxes.
    func toggleSelection(_ device: AirPlayDevice) async {
        let currentIDs = await engine.selectedDevices().map(\.id)
        var newIDs = currentIDs
        if let idx = newIDs.firstIndex(of: device.id) {
            newIDs.remove(at: idx)
        } else {
            if newIDs.count < 8 {
                newIDs.append(device.id)
            }
        }
        await setSelectedDevices(newIDs)
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
        Task { await advertiser.start(port: UInt16(port)) }
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
        await advertiser.stop()
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
