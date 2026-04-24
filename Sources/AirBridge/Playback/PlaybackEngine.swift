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

    func setSelectedDevices(_ devices: [AirPlayDevice]) async {
        // implemented in next task
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
