import Foundation
import os

/// Playback is implemented on top of an `AirPlaySession` which — once Phases 2–5
/// are complete — will stream audio directly to a HomePod over AirPlay 2. Phase 1
/// holds the session skeleton; actual playback calls throw "not implemented" until
/// the protocol stack lands.
actor PlaybackEngine {
    private(set) var state: PlaybackState = .idle

    private var sessions: [String: AirPlaySession] = [:]
    private var order: [String] = []
    private var deviceSnapshots: [String: AirPlayDevice] = [:]
    private var statuses: [String: DeviceStatus] = [:]
    private weak var discovery: BonjourDiscovery?

    private var statusCallback: (@Sendable ([SelectedDevice]) -> Void)?
    private var stateCallback: (@Sendable (PlaybackState) -> Void)?
    private var trackFinishedCallback: (@Sendable () async -> Void)?

    var sessionFactory: @Sendable () -> AirPlaySession = { AirPlaySession() }

    init() {
        // no longer initializes a single session
    }

    func setStatusCallback(_ callback: @escaping @Sendable ([SelectedDevice]) -> Void) {
        self.statusCallback = callback
    }

    func selectedDevices() -> [SelectedDevice] {
        return order.compactMap { id in
            guard let snap = deviceSnapshots[id], let stat = statuses[id] else { return nil }
            return SelectedDevice(id: id, displayName: snap.displayName, status: stat)
        }
    }

    func setStateCallback(_ callback: @escaping @Sendable (PlaybackState) -> Void) {
        self.stateCallback = callback
    }

    func setTrackFinishedCallback(_ callback: @escaping @Sendable () async -> Void) {
        self.trackFinishedCallback = callback
    }

    func attachDiscovery(_ d: BonjourDiscovery) {
        self.discovery = d
    }

    // MARK: - Device selection

    /// Point the engine at a discovered AirPlay device. Pass nil to clear.
    func setDevice(_ device: AirPlayDevice?) async {
        if let d = device {
            await setSelectedDevices([d])
        } else {
            await setSelectedDevices([])
        }
    }

    var currentDevice: AirPlayDevice? {
        get async {
            guard let firstID = order.first else { return nil }
            return deviceSnapshots[firstID]
        }
    }

    func setSelectedDevices(_ requested: [AirPlayDevice]) async {
        let requestedIDs = requested.map { $0.id }
        let currentIDs = Set(order)
        let reqSet = Set(requestedIDs)

        let toRemove = currentIDs.subtracting(reqSet)
        for id in toRemove {
            await sessions[id]?.stop()
            sessions.removeValue(forKey: id)
            statuses.removeValue(forKey: id)
            deviceSnapshots.removeValue(forKey: id)
        }

        let toAdd = reqSet.subtracting(currentIDs)
        for d in requested where toAdd.contains(d.id) {
            let session = sessionFactory()
            if let discovery { await session.attachDiscovery(discovery) }
            await session.setDevice(d)

            sessions[d.id] = session
            deviceSnapshots[d.id] = d
            statuses[d.id] = .pairing

            if !d.supportsAirPlay2 {
                statuses[d.id] = .error(reason: "AirPlay 2 required")
                continue
            }

            Task { [weak self, id = d.id] in
                do {
                    try await session.connect()
                    await self?.updateStatus(id: id, status: .ok)
                } catch {
                    await self?.updateStatus(id: id, status: .error(reason: error.localizedDescription))
                }
            }
        }

        order = requestedIDs
        // update displayNames for existing devices in case of rename
        for d in requested {
            if deviceSnapshots[d.id] != nil {
                deviceSnapshots[d.id] = d
            }
        }

        fireStatusCallback()
    }

    private func updateStatus(id: String, status: DeviceStatus) {
        if statuses[id] != nil {
            statuses[id] = status
            fireStatusCallback()
        }
    }

    private func fireStatusCallback() {
        let snap = selectedDevices()
        statusCallback?(snap)
    }

    /// Legacy hook kept for API compatibility with earlier UID-based callers;
    /// a no-op in the AirPlay architecture because routing is by Bonjour device,
    /// not CoreAudio UID.
    func setOutputDevice(uid: String) async throws -> Bool { false }
    var outputDeviceUID: String? { nil }

    // MARK: - Playback

    func play(track: QueueTrack) async throws {
        // TODO: Update in next task
        let _ = URL(fileURLWithPath: track.stagedPath)
        transition(to: .playing(file: track.originalFilename))
        Log.playback.info("Playing \(track.originalFilename, privacy: .public)")
    }

    func stop() async -> PlaybackState {
        // TODO: Update in next task
        transition(to: .idle)
        return state
    }

    func pause() -> PlaybackState {
        // Pause semantics depend on the RTP streamer (Phase 5). For now, a pause
        // call while no real stream is running just transitions state.
        if case .playing(let file) = state {
            transition(to: .paused(file: file))
        }
        return state
    }

    func resume() -> PlaybackState {
        if case .paused(let file) = state {
            transition(to: .playing(file: file))
        }
        return state
    }

    // MARK: - Private

    private func transition(to newState: PlaybackState) {
        let oldState = state
        state = newState
        if oldState != newState, let cb = stateCallback {
            let s = newState
            Task { @MainActor in cb(s) }
        }
    }
}

enum PlaybackEngineError: Error, Sendable {
    case deviceNotFound(uid: String)
    case deviceUnavailable(uid: String)
    case engineSetupFailed
    case noAirPlayRoute
}
