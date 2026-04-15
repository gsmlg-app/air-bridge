import AVFoundation
import Foundation

// MARK: - Delegate Forwarder

/// A separate NSObject-based class that acts as the AVAudioPlayerDelegate,
/// forwarding events to the PlaybackEngine actor. This avoids the
/// actor + NSObject inheritance issue under Swift 6 strict concurrency.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let engine: PlaybackEngine

    init(engine: PlaybackEngine) {
        self.engine = engine
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Log.playback.info("Playback finished (success: \(flag))")
        Task { await self.engine.handleFinished() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let msg = error?.localizedDescription ?? "Unknown decode error"
        Log.playback.error("Decode error: \(msg)")
        Task { await self.engine.handleDecodeError(message: msg) }
    }
}

// MARK: - PlaybackEngine

actor PlaybackEngine {
    private(set) var state: PlaybackState = .idle
    private var player: AVAudioPlayer?
    private var delegate: PlayerDelegate?
    private var stateCallback: (@Sendable (PlaybackState) -> Void)?

    func setStateCallback(_ callback: @escaping @Sendable (PlaybackState) -> Void) {
        self.stateCallback = callback
    }

    func play(path: String) throws -> PlaybackState {
        switch AudioValidator.validate(path: path) {
        case .failure(let error):
            throw error
        case .success:
            break
        }

        player?.stop()
        player = nil
        delegate = nil

        let url = URL(fileURLWithPath: path)
        let newPlayer = try AVAudioPlayer(contentsOf: url)
        let newDelegate = PlayerDelegate(engine: self)
        newPlayer.delegate = newDelegate
        newPlayer.play()
        player = newPlayer
        delegate = newDelegate

        Log.playback.info("Playing: \(path)")
        transition(to: .playing(file: path))
        return state
    }

    func stop() -> PlaybackState {
        player?.stop()
        player = nil
        delegate = nil
        Log.playback.info("Stopped playback")
        transition(to: .idle)
        return state
    }

    func pause() -> PlaybackState {
        guard case .playing(let file) = state else { return state }
        player?.pause()
        Log.playback.info("Paused: \(file)")
        transition(to: .paused(file: file))
        return state
    }

    func resume() -> PlaybackState {
        guard case .paused(let file) = state else { return state }
        player?.play()
        Log.playback.info("Resumed: \(file)")
        transition(to: .playing(file: file))
        return state
    }

    // MARK: - Internal delegate callbacks

    func handleFinished() {
        transition(to: .idle)
    }

    func handleDecodeError(message: String) {
        transition(to: .error(message: message))
    }

    // MARK: - Private

    private func transition(to newState: PlaybackState) {
        state = newState
        let cb = stateCallback
        let s = newState
        Task { @MainActor in
            cb?(s)
        }
    }
}
