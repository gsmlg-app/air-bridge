import XCTest
import AVFoundation
@testable import AirBridge

actor MusicControllerSpy: MusicAppControlling {
    private let playError: Error?
    private var playRequests: [(URL, [String])] = []
    private var stopCount = 0
    private var pauseCount = 0
    private var resumeCount = 0

    init(playError: Error? = nil) {
        self.playError = playError
    }

    func devices() async throws -> [MusicAirPlayDevice] {
        []
    }

    func play(fileURL: URL, deviceIDs: [String]) async throws {
        if let playError {
            throw playError
        }
        playRequests.append((fileURL, deviceIDs))
    }

    func stop() async throws {
        stopCount += 1
    }

    func pause() async throws {
        pauseCount += 1
    }

    func resume() async throws {
        resumeCount += 1
    }

    func recordedPlayRequests() -> [(URL, [String])] {
        playRequests
    }
}

final class PlaybackEngineTests: XCTestCase {
    func testInitialOutputDeviceUsesSystemDefault() async {
        let engine = PlaybackEngine()

        let outputUID = await engine.outputDeviceUID

        XCTAssertNil(outputUID)
    }

    func testSetOutputDeviceRejectsUnknownCoreAudioUID() async {
        let engine = PlaybackEngine()

        do {
            _ = try await engine.setOutputDevice(uid: "missing-coreaudio-device")
            XCTFail("Expected unknown CoreAudio UID to be rejected")
        } catch PlaybackEngineError.deviceNotFound(let uid) {
            XCTAssertEqual(uid, "missing-coreaudio-device")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testClearOutputDeviceReturnsToSystemDefault() async {
        let engine = PlaybackEngine()

        await engine.clearOutputDevice()

        let outputUID = await engine.outputDeviceUID
        XCTAssertNil(outputUID)
    }

    func testSetOutputDeviceUpdatesInjectedPlayer() async throws {
        let defaultID = AudioDeviceManager.getDefaultOutputDeviceID()
        guard let defaultUID = AudioDeviceManager.deviceUID(for: defaultID) else {
            throw XCTSkip("No CoreAudio default output UID available")
        }
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)

        _ = try await engine.setOutputDevice(uid: defaultUID)

        XCTAssertEqual(player.audioOutputDeviceUniqueID, defaultUID)
    }

    func testPlayUsesMusicControllerForAllSelectedHomePods() async throws {
        let musicController = MusicControllerSpy()
        let engine = PlaybackEngine(player: AVPlayer(), musicController: musicController)
        await engine.setMusicAirPlayDeviceIDs(["bedroom-id", "electrical-center-id"])
        let track = QueueTrack(
            id: UUID(),
            originalFilename: "voice.mp3",
            stagedPath: "/tmp/voice.mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )

        try await engine.play(track: track)

        let requests = await musicController.recordedPlayRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0.path, "/tmp/voice.mp3")
        XCTAssertEqual(requests.first?.1, ["bedroom-id", "electrical-center-id"])
    }

    func testMusicPlaybackFailureTransitionsToError() async throws {
        let musicController = MusicControllerSpy(playError: MusicAppBridgeError.noSelectedDevices)
        let engine = PlaybackEngine(player: AVPlayer(), musicController: musicController)
        await engine.setMusicAirPlayDeviceIDs(["missing-homepod"])
        let track = QueueTrack(
            id: UUID(),
            originalFilename: "voice.mp3",
            stagedPath: "/tmp/voice.mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )

        do {
            try await engine.play(track: track)
            XCTFail("Expected Music playback failure")
        } catch MusicAppBridgeError.noSelectedDevices {
            let state = await engine.state
            XCTAssertEqual(state, .error(message: MusicAppBridgeError.noSelectedDevices.localizedDescription))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
