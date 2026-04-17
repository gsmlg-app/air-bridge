import AVFoundation
import CoreAudio
import os

actor PlaybackEngine {
    private(set) var state: PlaybackState = .idle

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var currentDeviceUID: String?
    private var stateCallback: (@Sendable (PlaybackState) -> Void)?
    private var trackFinishedCallback: (@Sendable () async -> Void)?

    func setStateCallback(_ callback: @escaping @Sendable (PlaybackState) -> Void) {
        self.stateCallback = callback
    }

    func setTrackFinishedCallback(_ callback: @escaping @Sendable () async -> Void) {
        self.trackFinishedCallback = callback
    }

    // MARK: - Output Device

    func setOutputDevice(uid: String) async throws -> Bool {
        let wasPlaying = state.isPlaying
        let oldUID = currentDeviceUID

        guard let deviceID = AudioDeviceManager.deviceID(forUID: uid) else {
            throw PlaybackEngineError.deviceNotFound(uid: uid)
        }

        if engine == nil {
            setupEngine()
        }

        guard let engine = engine else {
            throw PlaybackEngineError.engineSetupFailed
        }

        let audioUnit = engine.outputNode.audioUnit!
        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw PlaybackEngineError.deviceUnavailable(uid: uid)
        }

        currentDeviceUID = uid

        let hotSwapped = wasPlaying && oldUID != nil && oldUID != uid
        if hotSwapped {
            do {
                try engine.start()
                playerNode?.play()
            } catch {
                transition(to: .error(message: "Failed to restart after device swap: \(error.localizedDescription)"))
                throw PlaybackEngineError.engineSetupFailed
            }
        }

        Log.output.info("Output device set to \(uid, privacy: .public), hot_swapped=\(hotSwapped)")
        return hotSwapped
    }

    var outputDeviceUID: String? { currentDeviceUID }

    // MARK: - Playback

    func play(track: QueueTrack) async throws {
        stopInternal()
        setupEngine()

        guard let engine = engine, let playerNode = playerNode else {
            transition(to: .error(message: "Audio engine setup failed"))
            throw PlaybackEngineError.engineSetupFailed
        }

        // Pin to saved device if set
        if let uid = currentDeviceUID, let deviceID = AudioDeviceManager.deviceID(forUID: uid) {
            let audioUnit = engine.outputNode.audioUnit!
            var devID = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: track.stagedPath))
            self.audioFile = file

            engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)

            try engine.start()

            playerNode.scheduleFile(file, at: nil) { [weak self] in
                guard let self else { return }
                Task {
                    await self.handlePlaybackFinished()
                }
            }
            playerNode.play()

            transition(to: .playing(file: track.originalFilename))
            Log.playback.info("Playing: \(track.originalFilename, privacy: .public)")
        } catch {
            transition(to: .error(message: "Playback failed: \(error.localizedDescription)"))
            throw error
        }
    }

    func stop() -> PlaybackState {
        stopInternal()
        transition(to: .idle)
        return state
    }

    func pause() -> PlaybackState {
        guard case .playing(let file) = state else { return state }
        playerNode?.pause()
        engine?.pause()
        transition(to: .paused(file: file))
        return state
    }

    func resume() -> PlaybackState {
        guard case .paused = state, let engine = engine, let playerNode = playerNode else { return state }
        do {
            try engine.start()
            playerNode.play()
            if case .paused(let file) = state {
                transition(to: .playing(file: file))
            }
        } catch {
            transition(to: .error(message: "Resume failed: \(error.localizedDescription)"))
        }
        return state
    }

    // MARK: - Private

    private func setupEngine() {
        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        self.engine = eng
        self.playerNode = node
    }

    private func stopInternal() {
        playerNode?.stop()
        engine?.stop()
        engine?.reset()
        playerNode = nil
        engine = nil
        audioFile = nil
    }

    private func handlePlaybackFinished() {
        guard state.isPlaying else { return }
        transition(to: .idle)
        Log.playback.info("Track finished")

        if let cb = trackFinishedCallback {
            Task { await cb() }
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

enum PlaybackEngineError: Error, Sendable {
    case deviceNotFound(uid: String)
    case deviceUnavailable(uid: String)
    case engineSetupFailed
}
