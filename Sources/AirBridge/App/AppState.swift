import AVFoundation
import Foundation
import Hummingbird
import SwiftUI
import os

@MainActor
final class AppState: ObservableObject {
    typealias OutputDeviceProvider = @MainActor (String?) -> [AudioOutputDeviceInfo]

    @Published var playbackState: PlaybackState = .idle
    @Published var queueState: QueueState = QueueState()
    @Published var outputDevices: [AudioOutputDeviceInfo] = []
    @Published var musicAirPlayDevices: [MusicAirPlayDevice] = []
    @Published var selectedMusicAirPlayDeviceIDs: [String] = []
    @Published var musicAirPlayError: String?
    @Published var currentOutputName: String = "System Default"

    @Published var listenAddress: String
    @Published var serverPort: Int
    @Published var authToken: String
    @Published var serverRunning: Bool = false

    let routePickerPlayer: AVPlayer
    let engine: PlaybackEngine
    let queue: PlaybackQueue
    let advertiser = ServiceAdvertiser()
    private let musicController: MusicAppBridge
    private struct ServerRun {
        let id: UUID
        let task: Task<Void, Never>
    }
    private struct ServerRestartRun {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var serverRun: ServerRun?
    private var serverRestartRun: ServerRestartRun?
    private var periodicStateSyncTask: Task<Void, Never>?
    private let outputDeviceProvider: OutputDeviceProvider
    private static let musicAirPlayDeviceIDsKey = "musicAirPlayDeviceIDs"

    init(
        startBackgroundWork: Bool = true,
        outputDeviceProvider: @escaping OutputDeviceProvider = {
            AudioDeviceManager.allOutputDevices(engineTargetUID: $0)
        }
    ) {
        self.listenAddress = UserDefaults.standard.string(forKey: "listenAddress") ?? "127.0.0.1"
        let portStr = UserDefaults.standard.string(forKey: "serverPort") ?? "9876"
        self.serverPort = Int(portStr) ?? 9876
        self.authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""
        self.selectedMusicAirPlayDeviceIDs = UserDefaults.standard.array(forKey: Self.musicAirPlayDeviceIDsKey) as? [String] ?? []

        let player = AVPlayer()
        let musicController = MusicAppBridge()
        self.musicController = musicController
        self.outputDeviceProvider = outputDeviceProvider
        self.routePickerPlayer = player
        let engine = PlaybackEngine(player: player, musicController: musicController)
        self.engine = engine
        self.queue = PlaybackQueue(engine: engine)

        guard startBackgroundWork else { return }

        Task {
            await engine.setMusicAirPlayDeviceIDs(selectedMusicAirPlayDeviceIDs)
            await engine.setStateCallback { [weak self] newState in
                Task { @MainActor in
                    self?.playbackState = newState
                }
            }
        }

        if !selectedMusicAirPlayDeviceIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: "engineOutputDeviceUID")
        }
        let savedUID = selectedMusicAirPlayDeviceIDs.isEmpty ? UserDefaults.standard.string(forKey: "engineOutputDeviceUID") : nil
        let restorableUID = OutputRoutingPolicy.restorablePinnedUID(
            from: savedUID,
            transportForUID: OutputRoutingPolicy.transportForUID
        )
        if savedUID != restorableUID {
            UserDefaults.standard.removeObject(forKey: "engineOutputDeviceUID")
        }

        if let savedUID = restorableUID {
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.engine.setOutputDevice(uid: savedUID)
                } catch {
                    Log.output.error("Failed to restore output device \(savedUID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    UserDefaults.standard.removeObject(forKey: "engineOutputDeviceUID")
                }
                await MainActor.run { self.refreshOutputDevices() }
            }
        } else {
            refreshOutputDevices()
        }

        Task {
            await refreshMusicAirPlayDevices()
        }

        startPeriodicStateSync()

        startServer()
    }

    deinit {
        periodicStateSyncTask?.cancel()
        serverRestartRun?.task.cancel()
        serverRun?.task.cancel()
    }

    func setOutputDevice(uid: String?) async throws -> Bool {
        if let uid, !uid.isEmpty {
            await clearMusicAirPlaySelection()
            let hotSwapped = try await engine.setOutputDevice(uid: uid)
            UserDefaults.standard.set(uid, forKey: "engineOutputDeviceUID")
            refreshOutputDevices(engineTargetUID: uid)
            return hotSwapped
        }

        await engine.clearOutputDevice()
        UserDefaults.standard.removeObject(forKey: "engineOutputDeviceUID")
        refreshOutputDevices(engineTargetUID: nil)
        return false
    }

    func setMusicAirPlayDevice(id: String, selected: Bool) async {
        var ids = selectedMusicAirPlayDeviceIDs
        if selected {
            if !ids.contains(id) {
                ids.append(id)
            }
            await engine.clearOutputDevice()
            UserDefaults.standard.removeObject(forKey: "engineOutputDeviceUID")
        } else {
            ids.removeAll { $0 == id }
        }

        selectedMusicAirPlayDeviceIDs = ids
        UserDefaults.standard.set(ids, forKey: Self.musicAirPlayDeviceIDsKey)
        await engine.setMusicAirPlayDeviceIDs(ids)
        syncMusicAirPlayDeviceSelection()
        refreshOutputDevices(engineTargetUID: nil)
    }

    func clearMusicAirPlaySelection() async {
        guard !selectedMusicAirPlayDeviceIDs.isEmpty else { return }
        selectedMusicAirPlayDeviceIDs = []
        UserDefaults.standard.removeObject(forKey: Self.musicAirPlayDeviceIDsKey)
        await engine.setMusicAirPlayDeviceIDs([])
        syncMusicAirPlayDeviceSelection()
    }

    func clearPinnedOutputForSystemRouting() async {
        await engine.clearOutputDevice()
        UserDefaults.standard.removeObject(forKey: "engineOutputDeviceUID")
        refreshOutputDevices(engineTargetUID: nil)
    }

    func refreshMusicAirPlayDevices() async {
        do {
            musicAirPlayDevices = try await musicController.devices()
            if selectedMusicAirPlayDeviceIDs.isEmpty {
                let migratedIDs = MusicAirPlaySelectionMigration.migratedDeviceIDs(
                    fromLegacyIDs: Self.legacySelectedAirPlayDeviceIDs(),
                    devices: musicAirPlayDevices
                )
                if !migratedIDs.isEmpty {
                    selectedMusicAirPlayDeviceIDs = migratedIDs
                    UserDefaults.standard.set(migratedIDs, forKey: Self.musicAirPlayDeviceIDsKey)
                    await engine.setMusicAirPlayDeviceIDs(migratedIDs)
                    UserDefaults.standard.removeObject(forKey: "engineOutputDeviceUID")
                }
            }
            syncMusicAirPlayDeviceSelection()
            musicAirPlayError = nil
        } catch {
            musicAirPlayError = error.localizedDescription
        }
    }

    func refreshOutputDevices(engineTargetUID: String? = nil) {
        let targetUID = engineTargetUID ?? UserDefaults.standard.string(forKey: "engineOutputDeviceUID")
        let devices = outputDeviceProvider(targetUID)
        let outputName: String

        if !selectedMusicAirPlayDeviceIDs.isEmpty {
            let names = musicAirPlayDevices
                .filter { selectedMusicAirPlayDeviceIDs.contains($0.id) }
                .map(\.name)
            outputName = names.isEmpty ? "Music AirPlay" : names.joined(separator: ", ")
        } else if let targetUID, let target = devices.first(where: { $0.id == targetUID }) {
            outputName = target.name
        } else if let currentDefault = devices.first(where: { $0.isSystemDefault }) {
            outputName = "\(currentDefault.name) (System Default)"
        } else {
            outputName = "System Default"
        }

        if outputDevices != devices {
            outputDevices = devices
        }
        if currentOutputName != outputName {
            currentOutputName = outputName
        }
    }

    func startPeriodicStateSync() {
        guard periodicStateSyncTask == nil else { return }

        periodicStateSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }

                guard !Task.isCancelled, let self else { return }
                await self.syncStateOnce()
            }
        }
    }

    func syncStateOnce() async {
        let newQueueState = await queue.list()
        let engineUID = await engine.outputDeviceUID

        if queueState != newQueueState {
            queueState = newQueueState
        }
        refreshOutputDevices(engineTargetUID: engineUID)
    }

    private func syncMusicAirPlayDeviceSelection() {
        let selectedIDs = Set(selectedMusicAirPlayDeviceIDs)
        musicAirPlayDevices = musicAirPlayDevices.map { device in
            var copy = device
            copy.selected = selectedIDs.contains(device.id)
            return copy
        }
    }

    private static func legacySelectedAirPlayDeviceIDs() -> [String] {
        if let data = UserDefaults.standard.data(forKey: "selectedAirPlayDeviceIDs"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            return ids
        }
        if let id = UserDefaults.standard.string(forKey: "selectedAirPlayDeviceID") {
            return [id]
        }
        return []
    }
}

extension AppState {
    func startServer() {
        guard serverRun == nil else { return }
        let engine = self.engine
        let queue = self.queue
        let address = self.listenAddress
        let port = self.serverPort
        let authToken = self.authToken
        let runID = UUID()

        self.serverRunning = true
        advertiser.start(port: UInt16(port))
        let task = Task.detached { [weak self] in
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
            } catch is CancellationError {
                Log.server.info("Server task cancelled")
            } catch {
                Log.server.error("Server failed: \(error)")
            }
            await self?.serverDidExit(runID: runID)
        }
        self.serverRun = ServerRun(id: runID, task: task)
    }

    func stopServer() async {
        advertiser.stop()
        guard let run = serverRun else {
            serverRunning = false
            return
        }
        Log.server.info("Stopping server")
        run.task.cancel()
        _ = await run.task.value
        if serverRun?.id == run.id {
            serverRun = nil
            serverRunning = false
        }
    }

    @discardableResult
    func restartServer() async -> UUID {
        if let activeRestart = serverRestartRun {
            await activeRestart.task.value
            if serverRestartRun?.id == activeRestart.id {
                serverRestartRun = nil
            }
            return activeRestart.id
        }

        let restartID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performServerRestart()
        }
        serverRestartRun = ServerRestartRun(id: restartID, task: task)

        await task.value
        if serverRestartRun?.id == restartID {
            serverRestartRun = nil
        }
        return restartID
    }

    private func performServerRestart() async {
        await stopServer()

        self.listenAddress = UserDefaults.standard.string(forKey: "listenAddress") ?? "127.0.0.1"
        let portStr = UserDefaults.standard.string(forKey: "serverPort") ?? "9876"
        self.serverPort = Int(portStr) ?? 9876
        self.authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""

        startServer()
    }

    private func serverDidExit(runID: UUID) {
        guard serverRun?.id == runID else { return }
        serverRun = nil
        serverRunning = false
        advertiser.stop()
    }
}
