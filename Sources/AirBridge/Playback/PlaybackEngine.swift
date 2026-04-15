import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

actor PlaybackEngine {
    private(set) var state: PlaybackState = .idle
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var outputDeviceID: AudioDeviceID = 0
    private var stateCallback: (@Sendable (PlaybackState) -> Void)?

    func setStateCallback(_ callback: @escaping @Sendable (PlaybackState) -> Void) {
        self.stateCallback = callback
    }

    func setOutputDevice(_ deviceID: AudioDeviceID) {
        self.outputDeviceID = deviceID
        Log.playback.info("Output device set to ID \(deviceID)")
    }

    func play(path: String) throws -> PlaybackState {
        switch AudioValidator.validate(path: path) {
        case .failure(let error):
            throw error
        case .success:
            break
        }

        // Stop any current playback
        stopInternal()

        // Set up audio engine
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        // Load the audio file
        let url = URL(fileURLWithPath: path)
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            Log.playback.error("Failed to read audio file: \(error)")
            transition(to: .error(message: "Failed to read audio file: \(error.localizedDescription)"))
            return state
        }

        // Connect player to output
        engine.connect(player, to: engine.mainMixerNode, format: audioFile.processingFormat)

        // Set output device if configured
        if outputDeviceID != 0 {
            let outputNode = engine.outputNode
            if let audioUnit = outputNode.audioUnit {
                var deviceID = outputDeviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status == noErr {
                    Log.playback.info("Routed audio to device ID \(self.outputDeviceID)")
                } else {
                    Log.playback.warning("Failed to set output device (status: \(status)), using default")
                }
            }
        }

        // Start engine and schedule playback
        do {
            try engine.start()
        } catch {
            Log.playback.error("Failed to start audio engine: \(error)")
            transition(to: .error(message: "Audio engine failed: \(error.localizedDescription)"))
            return state
        }

        player.scheduleFile(audioFile, at: nil) { [weak self] in
            Task {
                await self?.handlePlaybackFinished()
            }
        }
        player.play()

        self.audioEngine = engine
        self.playerNode = player

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
        playerNode?.pause()
        Log.playback.info("Paused: \(file)")
        transition(to: .paused(file: file))
        return state
    }

    func resume() -> PlaybackState {
        guard case .paused(let file) = state else { return state }
        playerNode?.play()
        Log.playback.info("Resumed: \(file)")
        transition(to: .playing(file: file))
        return state
    }

    // MARK: - Internal

    private func stopInternal() {
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
    }

    private func handlePlaybackFinished() {
        // Only transition to idle if still playing (not already stopped)
        if case .playing = state {
            Log.playback.info("Playback finished")
            transition(to: .idle)
        }
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
