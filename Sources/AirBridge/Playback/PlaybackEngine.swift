import Foundation
import os

/// Playback is implemented on top of an `AirPlaySession` which — once Phases 2–5
/// are complete — will stream audio directly to a HomePod over AirPlay 2. Phase 1
/// holds the session skeleton; actual playback calls throw "not implemented" until
/// the protocol stack lands.
actor PlaybackEngine {
    private(set) var state: PlaybackState = .idle

    let session: AirPlaySession
    private var stateCallback: (@Sendable (PlaybackState) -> Void)?
    private var trackFinishedCallback: (@Sendable () async -> Void)?

    init(session: AirPlaySession = AirPlaySession()) {
        self.session = session
    }

    func setStateCallback(_ callback: @escaping @Sendable (PlaybackState) -> Void) {
        self.stateCallback = callback
    }

    func setTrackFinishedCallback(_ callback: @escaping @Sendable () async -> Void) {
        self.trackFinishedCallback = callback
    }

    // MARK: - Device selection

    /// Point the engine at a discovered AirPlay device. Pass nil to clear.
    func setDevice(_ device: AirPlayDevice?) async {
        await session.setDevice(device)
    }

    var currentDevice: AirPlayDevice? {
        get async { await session.currentDevice }
    }

    /// Legacy hook kept for API compatibility with earlier UID-based callers;
    /// a no-op in the AirPlay architecture because routing is by Bonjour device,
    /// not CoreAudio UID.
    func setOutputDevice(uid: String) async throws -> Bool { false }
    var outputDeviceUID: String? { nil }

    // MARK: - Playback

    func play(track: QueueTrack) async throws {
        let url = URL(fileURLWithPath: track.stagedPath)
        do {
            try await session.play(fileURL: url)
            transition(to: .playing(file: track.originalFilename))
            Log.playback.info("Playing \(track.originalFilename, privacy: .public)")
        } catch let error as AirPlayError {
            let msg = error.description
            transition(to: .error(message: msg))
            Log.playback.error("Playback refused: \(msg, privacy: .public)")
            throw error
        } catch {
            transition(to: .error(message: "Playback failed: \(error.localizedDescription)"))
            throw error
        }
    }

    func stop() async -> PlaybackState {
        await session.stop()
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
