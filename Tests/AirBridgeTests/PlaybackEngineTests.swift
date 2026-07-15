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

private actor SuspendedMusicController: MusicAppControlling {
    private var playContinuation: CheckedContinuation<Void, any Error>?
    private var playStartedContinuation: CheckedContinuation<Void, Never>?
    private var didStartPlay = false

    func devices() async throws -> [MusicAirPlayDevice] { [] }

    func play(fileURL: URL, deviceIDs: [String]) async throws {
        didStartPlay = true
        playStartedContinuation?.resume()
        playStartedContinuation = nil
        try await withCheckedThrowingContinuation { continuation in
            playContinuation = continuation
        }
    }

    func stop() async throws {}
    func pause() async throws {}
    func resume() async throws {}

    func waitUntilPlayStarts() async {
        if didStartPlay { return }
        await withCheckedContinuation { continuation in
            playStartedContinuation = continuation
        }
    }

    func completePlay() {
        playContinuation?.resume()
        playContinuation = nil
    }

    func failPlay() {
        playContinuation?.resume(throwing: MusicAppBridgeError.noSelectedDevices)
        playContinuation = nil
    }
}

actor PlaybackCallbackRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func recordedCount() -> Int {
        count
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

    func testStaleSuspendedMusicPlaySuccessDoesNotReviveAfterStop() async throws {
        let musicController = SuspendedMusicController()
        let engine = PlaybackEngine(player: AVPlayer(), musicController: musicController)
        await engine.setMusicAirPlayDeviceIDs(["bedroom-id"])
        let track = QueueTrack(
            id: UUID(),
            originalFilename: "delayed.mp3",
            stagedPath: "/tmp/delayed.mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )

        let playTask = Task {
            try await engine.play(track: track, token: UUID())
        }
        await musicController.waitUntilPlayStarts()
        _ = await engine.stop()
        await musicController.completePlay()
        try await playTask.value

        let state = await engine.state
        XCTAssertEqual(state, .idle)
        _ = await engine.stop()
    }

    func testStaleSuspendedMusicPlayFailureDoesNotReplaceIdleWithError() async {
        let musicController = SuspendedMusicController()
        let engine = PlaybackEngine(player: AVPlayer(), musicController: musicController)
        await engine.setMusicAirPlayDeviceIDs(["bedroom-id"])
        let track = QueueTrack(
            id: UUID(),
            originalFilename: "delayed.mp3",
            stagedPath: "/tmp/delayed.mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )

        let playTask = Task {
            try await engine.play(track: track, token: UUID())
        }
        await musicController.waitUntilPlayStarts()
        _ = await engine.stop()
        await musicController.failPlay()

        do {
            try await playTask.value
            XCTFail("Expected suspended Music playback to fail")
        } catch MusicAppBridgeError.noSelectedDevices {
            // Expected: the stale error is returned to its original caller only.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let state = await engine.state
        XCTAssertEqual(state, .idle)
    }

    func testAVPlayerItemFailureSkipsCurrentTrack() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)
        let callbackRecorder = PlaybackCallbackRecorder()
        await engine.setTrackFinishedCallback { _ in
            await callbackRecorder.record()
        }
        let track = QueueTrack(
            id: UUID(),
            originalFilename: "broken.mp3",
            stagedPath: "/tmp/broken.mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )

        try await engine.play(track: track)
        guard let item = player.currentItem else {
            XCTFail("Expected AVPlayerItem to be installed")
            return
        }

        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(domain: "AirBridgeTests", code: 1)]
        )

        try await waitForCallback(callbackRecorder)
        let state = await engine.state
        XCTAssertEqual(state, .idle)
        XCTAssertNil(player.currentItem)
    }

    func testPlaybackStallTimeoutSkipsCurrentTrack() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(
            player: player,
            stalledPlaybackTimeout: 0.05,
            stalledPlaybackCheckInterval: 0.01,
            playbackTimeProvider: { _ in 0 }
        )
        let callbackRecorder = PlaybackCallbackRecorder()
        await engine.setTrackFinishedCallback { _ in
            await callbackRecorder.record()
        }
        let track = QueueTrack(
            id: UUID(),
            originalFilename: "stuck.mp3",
            stagedPath: "/tmp/stuck.mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )

        try await engine.play(track: track)

        try await waitForCallback(callbackRecorder)
        let state = await engine.state
        XCTAssertEqual(state, .idle)
        XCTAssertNil(player.currentItem)
    }

    func testResumeResetsPlaybackStallTimeoutBaseline() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(
            player: player,
            stalledPlaybackTimeout: 0.2,
            stalledPlaybackCheckInterval: 0.01,
            playbackTimeProvider: { _ in 0 }
        )
        let callbackRecorder = PlaybackCallbackRecorder()
        await engine.setTrackFinishedCallback { _ in
            await callbackRecorder.record()
        }
        let track = QueueTrack(
            id: UUID(),
            originalFilename: "paused.mp3",
            stagedPath: "/tmp/paused.mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )

        try await engine.play(track: track)
        _ = await engine.pause()
        try await Task.sleep(nanoseconds: 300_000_000)
        let pausedCallbackCount = await callbackRecorder.recordedCount()
        XCTAssertEqual(pausedCallbackCount, 0)

        _ = await engine.resume()
        try await Task.sleep(nanoseconds: 50_000_000)

        let resumedState = await engine.state
        let resumedCallbackCount = await callbackRecorder.recordedCount()
        XCTAssertEqual(resumedState, .playing(file: "paused.mp3"))
        XCTAssertEqual(resumedCallbackCount, 0)
        _ = await engine.stop()
    }

    func testStaleNotificationTokenDoesNotStopReplacement() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)
        let callbackRecorder = PlaybackCallbackRecorder()
        await engine.setTrackFinishedCallback { _ in
            await callbackRecorder.record()
        }
        let oldTrack = QueueTrack(
            id: UUID(),
            originalFilename: "old.mp3",
            stagedPath: "/tmp/old.mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )
        let replacement = QueueTrack(
            id: UUID(),
            originalFilename: "replacement.mp3",
            stagedPath: "/tmp/replacement.mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )
        let oldToken = UUID()
        let replacementToken = UUID()

        try await engine.play(track: oldTrack, token: oldToken)
        try await engine.play(track: replacement, token: replacementToken)
        guard let replacementItem = player.currentItem else {
            XCTFail("Expected replacement AVPlayerItem")
            return
        }

        await engine.handlePlaybackFinished(token: oldToken)

        let state = await engine.state
        let callbackCount = await callbackRecorder.recordedCount()
        XCTAssertEqual(state, .playing(file: "replacement.mp3"))
        XCTAssertTrue(player.currentItem === replacementItem)
        XCTAssertEqual(callbackCount, 0)
        _ = await engine.stop()
    }

    func testStopDetachesCurrentAVPlayerItem() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)
        let track = QueueTrack(
            id: UUID(),
            originalFilename: "voice.mp3",
            stagedPath: "/tmp/voice.mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )

        try await engine.play(track: track)
        XCTAssertNotNil(player.currentItem)

        _ = await engine.stop()

        XCTAssertNil(player.currentItem)
    }

    private func waitForCallback(_ recorder: PlaybackCallbackRecorder) async throws {
        for _ in 0..<20 {
            if await recorder.recordedCount() > 0 {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Expected playback failure to notify the queue callback")
    }
}
