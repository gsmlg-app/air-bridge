import AVFoundation
import Foundation

actor PlaybackEngine {
    private(set) var state: PlaybackState = .idle
    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var endObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
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

        stopInternal()

        let url = URL(fileURLWithPath: path)
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)

        // Observe playback completion
        let endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handlePlaybackFinished() }
        }

        // Observe playback errors
        let errorObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let msg = error?.localizedDescription ?? "Unknown playback error"
            Task { await self?.handlePlaybackError(message: msg) }
        }

        avPlayer.play()

        self.player = avPlayer
        self.playerItem = item
        self.endObserver = endObs
        self.errorObserver = errorObs

        Log.playback.info("Playing: \(path)")
        transition(to: .playing(file: path))
        return state
    }

    func stop() -> PlaybackState {
        stopInternal()
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

    // MARK: - Internal

    private func stopInternal() {
        player?.pause()
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = errorObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        player = nil
        playerItem = nil
        endObserver = nil
        errorObserver = nil
    }

    private func handlePlaybackFinished() {
        if case .playing = state {
            Log.playback.info("Playback finished")
            stopInternal()
            transition(to: .idle)
        }
    }

    private func handlePlaybackError(message: String) {
        Log.playback.error("Playback error: \(message)")
        stopInternal()
        transition(to: .error(message: message))
    }

    private func transition(to newState: PlaybackState) {
        state = newState
        let cb = stateCallback
        let s = newState
        Task { @MainActor in
            cb?(s)
        }
    }
}
