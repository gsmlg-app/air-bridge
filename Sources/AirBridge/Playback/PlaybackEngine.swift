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
    private var playbackStallWatchdogTask: Task<Void, Never>?
    private var lastPlaybackProgressSeconds: TimeInterval = 0
    private var lastPlaybackProgressAt = Date()
    private var activePlaybackToken: UUID?

    private var stateCallback: (@Sendable (PlaybackState) -> Void)?
    private var trackFinishedCallback: (@Sendable (UUID) async -> Void)?

    private let stalledPlaybackTimeout: TimeInterval
    private let stalledPlaybackCheckInterval: TimeInterval
    private let playbackTimeProvider: (AVPlayer) -> TimeInterval

    init(
        player: AVPlayer = AVPlayer(),
        musicController: any MusicAppControlling = MusicAppBridge(),
        stalledPlaybackTimeout: TimeInterval = 15,
        stalledPlaybackCheckInterval: TimeInterval = 2,
        playbackTimeProvider: @escaping (AVPlayer) -> TimeInterval = { player in
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? seconds : 0
        }
    ) {
        self.player = player
        self.musicController = musicController
        self.stalledPlaybackTimeout = stalledPlaybackTimeout
        self.stalledPlaybackCheckInterval = stalledPlaybackCheckInterval
        self.playbackTimeProvider = playbackTimeProvider
        self.player.allowsExternalPlayback = true
    }

    func setStateCallback(_ callback: @escaping @Sendable (PlaybackState) -> Void) {
        self.stateCallback = callback
    }

    func setTrackFinishedCallback(_ callback: @escaping @Sendable (UUID) async -> Void) {
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

    func play(track: QueueTrack, token: UUID = UUID()) async throws {
        await stopInternal()
        activePlaybackToken = token

        let url = URL(fileURLWithPath: track.stagedPath)
        if currentDeviceUID == nil, !selectedMusicAirPlayDeviceIDs.isEmpty {
            do {
                try await musicController.play(fileURL: url, deviceIDs: selectedMusicAirPlayDeviceIDs)
            } catch {
                guard activePlaybackToken == token else { throw error }
                activePlaybackToken = nil
                transition(to: .error(message: error.localizedDescription))
                throw error
            }
            guard activePlaybackToken == token else { return }
            activeBackend = .musicApp
            scheduleMusicCompletion(for: url, token: token)
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
            Task { await self?.handlePlaybackFinished(token: token) }
        }

        let errorObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let message = error?.localizedDescription ?? "Unknown playback error"
            Task { await self?.handlePlaybackError(message: message, token: token) }
        }

        playerItem = item
        endObserver = endObs
        errorObserver = errorObs

        player.replaceCurrentItem(with: item)
        player.play()
        activeBackend = .avPlayer

        transition(to: .playing(file: track.originalFilename))
        startPlaybackStallWatchdog(token: token)
        Log.playback.info("Playing \(track.originalFilename, privacy: .public)")
    }

    func stop() async -> PlaybackState {
        await stopInternal()
        transition(to: .idle)
        return state
    }

    func resetPlaybackError() {
        guard case .error = state else { return }
        activePlaybackToken = nil
        transition(to: .idle)
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
            lastPlaybackProgressSeconds = currentPlaybackSeconds()
            lastPlaybackProgressAt = Date()
        }
        transition(to: .playing(file: file))
        return state
    }

    // MARK: - Private

    private func stopInternal(sendStopToActiveBackend: Bool = true) async {
        activePlaybackToken = nil
        player.pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let errorObserver {
            NotificationCenter.default.removeObserver(errorObserver)
        }
        player.replaceCurrentItem(with: nil)
        musicCompletionTask?.cancel()
        playbackStallWatchdogTask?.cancel()
        if sendStopToActiveBackend, activeBackend == .musicApp {
            try? await musicController.stop()
        }
        playerItem = nil
        endObserver = nil
        errorObserver = nil
        musicCompletionTask = nil
        playbackStallWatchdogTask = nil
        activeBackend = .avPlayer
    }

    func handlePlaybackFinished(token: UUID) async {
        guard activePlaybackToken == token, state.isPlaying else { return }
        await stopInternal(sendStopToActiveBackend: false)
        transition(to: .idle)
        Log.playback.info("Track finished")

        notifyTrackFinished(token: token)
    }

    private func handlePlaybackError(message: String, token: UUID) async {
        guard activePlaybackToken == token, state.isPlaying else { return }
        Log.playback.error("Playback error: \(message, privacy: .public)")
        await stopInternal(sendStopToActiveBackend: false)
        transition(to: .idle)
        notifyTrackFinished(token: token)
    }

    private func startPlaybackStallWatchdog(token: UUID) {
        playbackStallWatchdogTask?.cancel()
        lastPlaybackProgressSeconds = currentPlaybackSeconds()
        lastPlaybackProgressAt = Date()

        let interval = max(stalledPlaybackCheckInterval, 0.01)
        let intervalNanoseconds = UInt64(interval * 1_000_000_000)
        playbackStallWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.checkForStalledPlayback(token: token)
            }
        }
    }

    private func checkForStalledPlayback(token: UUID) async {
        guard activePlaybackToken == token,
              state.isPlaying,
              activeBackend == .avPlayer,
              playerItem != nil else { return }

        let now = Date()
        let currentSeconds = currentPlaybackSeconds()
        if currentSeconds > lastPlaybackProgressSeconds + 0.05 {
            lastPlaybackProgressSeconds = currentSeconds
            lastPlaybackProgressAt = now
            return
        }

        guard now.timeIntervalSince(lastPlaybackProgressAt) >= stalledPlaybackTimeout else { return }
        await handlePlaybackStalled(token: token)
    }

    private func currentPlaybackSeconds() -> TimeInterval {
        let seconds = playbackTimeProvider(player)
        return seconds.isFinite ? seconds : 0
    }

    private func handlePlaybackStalled(token: UUID) async {
        guard activePlaybackToken == token, state.isPlaying else { return }
        Log.playback.error("Playback stalled for \(self.stalledPlaybackTimeout, privacy: .public) seconds; skipping current track")
        await stopInternal(sendStopToActiveBackend: false)
        transition(to: .idle)
        notifyTrackFinished(token: token)
    }

    private func notifyTrackFinished(token: UUID) {
        if let cb = trackFinishedCallback {
            Task { await cb(token) }
        }
    }

    private func scheduleMusicCompletion(for url: URL, token: UUID) {
        musicCompletionTask?.cancel()
        musicCompletionTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { return }
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            let delay = UInt64((seconds + 1.0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.handlePlaybackFinished(token: token)
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
