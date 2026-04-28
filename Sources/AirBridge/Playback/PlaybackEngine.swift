import AVFoundation
import Foundation
import os

/// Plays queued local files through AVFoundation's player stack.
///
/// AirPlay/HomePod authentication is intentionally left to macOS. `AVPlayer`
/// follows the OS-authenticated AirPlay route selected through
/// `AVRoutePickerView` when `audioOutputDeviceUniqueID` is nil, and can also be
/// pinned to a CoreAudio output UID when macOS exposes one.
actor PlaybackEngine {
    private(set) var state: PlaybackState = .idle

    private let player: AVPlayer
    private let musicController: any MusicAppControlling
    private var playerItem: AVPlayerItem?
    private var endObserver: NSObjectProtocol?
    private var errorObserver: NSObjectProtocol?
    private var currentDeviceUID: String?
    private var selectedMusicAirPlayDeviceIDs: [String] = []
    private var activeBackend: PlaybackBackend = .avPlayer
    private var musicCompletionTask: Task<Void, Never>?

    private var stateCallback: (@Sendable (PlaybackState) -> Void)?
    private var trackFinishedCallback: (@Sendable () async -> Void)?

    init(player: AVPlayer = AVPlayer(), musicController: any MusicAppControlling = MusicAppBridge()) {
        self.player = player
        self.musicController = musicController
        self.player.allowsExternalPlayback = true
    }

    func setStateCallback(_ callback: @escaping @Sendable (PlaybackState) -> Void) {
        self.stateCallback = callback
    }

    func setTrackFinishedCallback(_ callback: @escaping @Sendable () async -> Void) {
        self.trackFinishedCallback = callback
    }

    // MARK: - Output Device

    func setOutputDevice(uid: String) async throws -> Bool {
        guard AudioDeviceManager.deviceID(forUID: uid) != nil else {
            throw PlaybackEngineError.deviceNotFound(uid: uid)
        }

        let oldUID = currentDeviceUID
        currentDeviceUID = uid
        player.audioOutputDeviceUniqueID = uid

        let hotSwapped = state.isPlaying && oldUID != nil && oldUID != uid
        Log.output.info("Output device set to \(uid, privacy: .public), hot_swapped=\(hotSwapped)")
        return hotSwapped
    }

    func clearOutputDevice() {
        currentDeviceUID = nil
        player.audioOutputDeviceUniqueID = nil
        Log.output.info("Output device target cleared; using system default")
    }

    var outputDeviceUID: String? { currentDeviceUID }

    func setMusicAirPlayDeviceIDs(_ ids: [String]) {
        selectedMusicAirPlayDeviceIDs = ids
    }

    var musicAirPlayDeviceIDs: [String] { selectedMusicAirPlayDeviceIDs }

    // MARK: - Playback

    func play(track: QueueTrack) async throws {
        await stopInternal()

        let url = URL(fileURLWithPath: track.stagedPath)
        if currentDeviceUID == nil, !selectedMusicAirPlayDeviceIDs.isEmpty {
            do {
                try await musicController.play(fileURL: url, deviceIDs: selectedMusicAirPlayDeviceIDs)
            } catch {
                transition(to: .error(message: error.localizedDescription))
                throw error
            }
            activeBackend = .musicApp
            scheduleMusicCompletion(for: url)
            transition(to: .playing(file: track.originalFilename))
            Log.playback.info("Playing \(track.originalFilename, privacy: .public) through Music AirPlay devices")
            return
        }

        let item = AVPlayerItem(url: url)
        if let currentDeviceUID {
            player.audioOutputDeviceUniqueID = currentDeviceUID
        }

        let endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handlePlaybackFinished() }
        }

        let errorObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? "Unknown playback error"
            Task { await self?.handlePlaybackError(message: message) }
        }

        playerItem = item
        endObserver = endObs
        errorObserver = errorObs

        player.replaceCurrentItem(with: item)
        player.play()
        activeBackend = .avPlayer

        transition(to: .playing(file: track.originalFilename))
        Log.playback.info("Playing \(track.originalFilename, privacy: .public)")
    }

    func stop() async -> PlaybackState {
        await stopInternal()
        transition(to: .idle)
        return state
    }

    func pause() async -> PlaybackState {
        guard case .playing(let file) = state else { return state }
        if activeBackend == .musicApp {
            try? await musicController.pause()
        } else {
            player.pause()
        }
        transition(to: .paused(file: file))
        return state
    }

    func resume() async -> PlaybackState {
        guard case .paused(let file) = state else { return state }
        if activeBackend == .musicApp {
            try? await musicController.resume()
        } else {
            player.play()
        }
        transition(to: .playing(file: file))
        return state
    }

    // MARK: - Private

    private func stopInternal(sendStopToActiveBackend: Bool = true) async {
        player.pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let errorObserver {
            NotificationCenter.default.removeObserver(errorObserver)
        }
        musicCompletionTask?.cancel()
        if sendStopToActiveBackend, activeBackend == .musicApp {
            try? await musicController.stop()
        }
        playerItem = nil
        endObserver = nil
        errorObserver = nil
        musicCompletionTask = nil
        activeBackend = .avPlayer
    }

    private func handlePlaybackFinished() async {
        guard state.isPlaying else { return }
        await stopInternal(sendStopToActiveBackend: false)
        transition(to: .idle)
        Log.playback.info("Track finished")

        if let cb = trackFinishedCallback {
            Task { await cb() }
        }
    }

    private func handlePlaybackError(message: String) async {
        Log.playback.error("Playback error: \(message, privacy: .public)")
        await stopInternal()
        transition(to: .error(message: message))
    }

    private func scheduleMusicCompletion(for url: URL) {
        musicCompletionTask?.cancel()
        musicCompletionTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { return }
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            let delay = UInt64((seconds + 1.0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.handlePlaybackFinished()
        }
    }

    private func transition(to newState: PlaybackState) {
        let oldState = state
        state = newState
        if oldState != newState, let cb = stateCallback {
            let s = newState
            Task { @MainActor in cb(s) }
        }
    }
}

private enum PlaybackBackend {
    case avPlayer
    case musicApp
}

enum PlaybackEngineError: Error, Sendable {
    case deviceNotFound(uid: String)
    case deviceUnavailable(uid: String)
    case engineSetupFailed
    case noAirPlayRoute
}
