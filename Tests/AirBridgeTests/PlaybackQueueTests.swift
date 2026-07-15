import AVFoundation
import Foundation
import Testing
@testable import AirBridge

private actor QueueMusicControllerSpy: MusicAppControlling {
    private let failingPlayCalls: Set<Int>
    private var playCallCount = 0

    init(failingPlayCalls: Set<Int>) {
        self.failingPlayCalls = failingPlayCalls
    }

    func devices() async throws -> [MusicAirPlayDevice] { [] }

    func play(fileURL: URL, deviceIDs: [String]) async throws {
        playCallCount += 1
        if failingPlayCalls.contains(playCallCount) {
            throw MusicAppBridgeError.noSelectedDevices
        }
    }

    func stop() async throws {}
    func pause() async throws {}
    func resume() async throws {}
}

struct PlaybackQueueTests {
    private func makeTrack(filename: String = "test.mp3") -> QueueTrack {
        QueueTrack(
            id: UUID(),
            originalFilename: filename,
            stagedPath: "/tmp/\(UUID().uuidString).mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )
    }

    @Test func enqueue_addsTrack() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let track = makeTrack()
        let (id, position) = await queue.enqueue(track: track)
        #expect(id == track.id)
        #expect(position == 0)

        let state = await queue.list()
        #expect(state.tracks.count == 1)
    }

    @Test func enqueue_multipleTracksPreservesOrder() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let t1 = makeTrack(filename: "a.mp3")
        let t2 = makeTrack(filename: "b.mp3")
        let t3 = makeTrack(filename: "c.mp3")

        let (_, p1) = await queue.enqueue(track: t1)
        let (_, p2) = await queue.enqueue(track: t2)
        let (_, p3) = await queue.enqueue(track: t3)

        #expect(p1 == 0)
        #expect(p2 == 1)
        #expect(p3 == 2)

        let state = await queue.list()
        #expect(state.tracks.map(\.originalFilename) == ["a.mp3", "b.mp3", "c.mp3"])
    }

    @Test func playNow_replacesQueueWithSingleCurrentTrack() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        _ = await queue.enqueue(track: makeTrack(filename: "old-a.mp3"))
        _ = await queue.enqueue(track: makeTrack(filename: "old-b.mp3"))

        let immediate = makeTrack(filename: "now.mp3")
        await queue.playNow(track: immediate)

        let state = await queue.list()
        #expect(state.tracks == [immediate])
        #expect(state.currentIndex == 0)
    }

    @Test func remove_deletesTrack() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let track = makeTrack()
        _ = await queue.enqueue(track: track)

        let removed = await queue.remove(id: track.id)
        #expect(removed)

        let state = await queue.list()
        #expect(state.tracks.isEmpty)
    }

    @Test func remove_nonexistentReturnsFalse() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let removed = await queue.remove(id: UUID())
        #expect(!removed)
    }

    @Test func move_reordersTrack() async throws {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let t1 = makeTrack(filename: "a.mp3")
        let t2 = makeTrack(filename: "b.mp3")
        let t3 = makeTrack(filename: "c.mp3")
        _ = await queue.enqueue(track: t1)
        _ = await queue.enqueue(track: t2)
        _ = await queue.enqueue(track: t3)

        try await queue.move(id: t3.id, toPosition: 0)

        let state = await queue.list()
        #expect(state.tracks.map(\.originalFilename) == ["c.mp3", "a.mp3", "b.mp3"])
    }

    @Test func clear_removesAllTracks() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        _ = await queue.enqueue(track: makeTrack(filename: "a.mp3"))
        _ = await queue.enqueue(track: makeTrack(filename: "b.mp3"))

        await queue.clear()

        let state = await queue.list()
        #expect(state.tracks.isEmpty)
        #expect(state.currentIndex == nil)
    }

    @Test func playbackFailure_advancesToNextTrack() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)
        let queue = PlaybackQueue(engine: engine)
        let broken = makeTrack(filename: "broken.mp3")
        let next = makeTrack(filename: "next.mp3")

        _ = await queue.enqueue(track: broken)
        _ = await queue.enqueue(track: next)
        guard let item = player.currentItem else {
            Issue.record("Expected current AVPlayerItem")
            return
        }

        NotificationCenter.default.post(
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: NSError(domain: "AirBridgeTests", code: 1)]
        )

        try await waitUntil {
            let state = await queue.list()
            return state.currentTrack?.id == next.id
        }
        let state = await queue.list()
        #expect(state.currentIndex == 1)
        #expect(state.currentTrack?.id == next.id)
    }

    @Test func playbackStallTimeout_advancesToNextTrack() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(
            player: player,
            stalledPlaybackTimeout: 0.05,
            stalledPlaybackCheckInterval: 0.01,
            playbackTimeProvider: { _ in 0 }
        )
        let queue = PlaybackQueue(engine: engine)
        let stuck = makeTrack(filename: "stuck.mp3")
        let next = makeTrack(filename: "next.mp3")

        _ = await queue.enqueue(track: stuck)
        _ = await queue.enqueue(track: next)

        try await waitUntil {
            let state = await queue.list()
            return state.currentTrack?.id == next.id
        }
        let state = await queue.list()
        #expect(state.currentIndex == 1)
        #expect(state.currentTrack?.id == next.id)
    }

    @Test func naturalExhaustion_clearsHistoryAndStartsNextBatchAtZero() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)
        let queue = PlaybackQueue(engine: engine)
        let finished = try makeStagedTrack(filename: "finished.mp3")
        defer { try? FileManager.default.removeItem(atPath: finished.stagedPath) }

        _ = await queue.enqueue(track: finished)
        guard let item = player.currentItem else {
            Issue.record("Expected current AVPlayerItem")
            return
        }

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)

        try await waitUntil {
            await queue.list().isEmpty
        }
        #expect(!FileManager.default.fileExists(atPath: finished.stagedPath))

        let nextBatch = makeTrack(filename: "next-batch.mp3")
        let (_, position) = await queue.enqueue(track: nextBatch)
        let state = await queue.list()
        #expect(position == 0)
        #expect(state.tracks == [nextBatch])
        #expect(state.currentIndex == 0)

        await queue.clear()
    }

    @Test func continuousProducer_keepsOnlyOneCompletedTrack() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)
        let queue = PlaybackQueue(engine: engine)
        let first = try makeStagedTrack(filename: "first.mp3")
        let second = try makeStagedTrack(filename: "second.mp3")
        let third = try makeStagedTrack(filename: "third.mp3")
        let fourth = try makeStagedTrack(filename: "fourth.mp3")
        defer {
            for track in [first, second, third, fourth] {
                try? FileManager.default.removeItem(atPath: track.stagedPath)
            }
        }

        _ = await queue.enqueue(track: first)
        _ = await queue.enqueue(track: second)
        try await finishCurrentTrack(player: player, queue: queue, expectedNext: second)

        _ = await queue.enqueue(track: third)
        try await finishCurrentTrack(player: player, queue: queue, expectedNext: third)

        var state = await queue.list()
        #expect(state.tracks == [second, third])
        #expect(state.currentIndex == 1)
        #expect(!FileManager.default.fileExists(atPath: first.stagedPath))

        _ = await queue.enqueue(track: fourth)
        try await finishCurrentTrack(player: player, queue: queue, expectedNext: fourth)

        state = await queue.list()
        #expect(state.tracks == [third, fourth])
        #expect(state.currentIndex == 1)
        #expect(!FileManager.default.fileExists(atPath: second.stagedPath))
        await queue.clear()
    }

    @Test func previous_remainsAvailableWhileBatchIsActive() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)
        let queue = PlaybackQueue(engine: engine)
        let first = makeTrack(filename: "first.mp3")
        let second = makeTrack(filename: "second.mp3")

        _ = await queue.enqueue(track: first)
        _ = await queue.enqueue(track: second)
        guard let item = player.currentItem else {
            Issue.record("Expected current AVPlayerItem")
            return
        }
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try await waitUntil {
            await queue.list().currentTrack?.id == second.id
        }

        let previous = await queue.previous()

        #expect(previous?.id == first.id)
        #expect(await queue.list().tracks == [first, second])
        await queue.clear()
    }

    @Test func staleCompletionAfterPlayNow_doesNotClearReplacement() async throws {
        let player = AVPlayer()
        let engine = PlaybackEngine(player: player)
        let queue = PlaybackQueue(engine: engine)
        let oldTrack = try makeStagedTrack(filename: "old.mp3")
        let replacement = try makeStagedTrack(filename: "replacement.mp3")
        defer {
            try? FileManager.default.removeItem(atPath: oldTrack.stagedPath)
            try? FileManager.default.removeItem(atPath: replacement.stagedPath)
        }

        _ = await queue.enqueue(track: oldTrack)
        guard let oldToken = await queue.activePlaybackToken else {
            Issue.record("Expected an active token for the old track")
            return
        }

        await queue.playNow(track: replacement)
        guard let replacementToken = await queue.activePlaybackToken else {
            Issue.record("Expected an active token for the replacement")
            return
        }
        #expect(replacementToken != oldToken)

        await queue.handleTrackFinished(token: oldToken)

        let state = await queue.list()
        #expect(state.tracks == [replacement])
        #expect(state.currentIndex == 0)
        #expect(await queue.activePlaybackToken == replacementToken)
        #expect(FileManager.default.fileExists(atPath: replacement.stagedPath))
        await queue.clear()
    }

    @Test func playbackStartFailuresAreRemovedAndSkippedIteratively() async throws {
        let controller = QueueMusicControllerSpy(failingPlayCalls: [2, 3])
        let engine = PlaybackEngine(player: AVPlayer(), musicController: controller)
        await engine.setMusicAirPlayDeviceIDs(["test-device"])
        let queue = PlaybackQueue(engine: engine)
        let first = makeTrack(filename: "first.mp3")
        let failedOne = try makeStagedTrack(filename: "failed-one.mp3")
        let failedTwo = try makeStagedTrack(filename: "failed-two.mp3")
        defer {
            try? FileManager.default.removeItem(atPath: failedOne.stagedPath)
            try? FileManager.default.removeItem(atPath: failedTwo.stagedPath)
        }
        let final = makeTrack(filename: "final.mp3")

        _ = await queue.enqueue(track: first)
        _ = await queue.enqueue(track: failedOne)
        _ = await queue.enqueue(track: failedTwo)
        _ = await queue.enqueue(track: final)

        let selected = await queue.next()

        #expect(selected?.id == final.id)
        let state = await queue.list()
        #expect(state.tracks == [first, final])
        #expect(state.currentIndex == 1)
        #expect(!FileManager.default.fileExists(atPath: failedOne.stagedPath))
        #expect(!FileManager.default.fileExists(atPath: failedTwo.stagedPath))
        await queue.clear()
    }

    @Test func onlyPlaybackStartFailureClearsQueueAndReturnsEngineToIdle() async throws {
        let controller = QueueMusicControllerSpy(failingPlayCalls: [1])
        let engine = PlaybackEngine(player: AVPlayer(), musicController: controller)
        await engine.setMusicAirPlayDeviceIDs(["test-device"])
        let queue = PlaybackQueue(engine: engine)
        let failed = try makeStagedTrack(filename: "failed.mp3")
        defer { try? FileManager.default.removeItem(atPath: failed.stagedPath) }

        _ = await queue.enqueue(track: failed)

        #expect(await queue.list().isEmpty)
        #expect(await engine.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: failed.stagedPath))
    }

    @Test func list_returnsCurrentState() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let state = await queue.list()
        #expect(state.isEmpty)
        #expect(state.currentIndex == nil)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<20 {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("Condition was not met before timeout")
    }

    private func finishCurrentTrack(
        player: AVPlayer,
        queue: PlaybackQueue,
        expectedNext: QueueTrack
    ) async throws {
        guard let item = player.currentItem else {
            Issue.record("Expected current AVPlayerItem")
            return
        }
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try await waitUntil {
            await queue.list().currentTrack?.id == expectedNext.id
        }
    }

    private func makeStagedTrack(filename: String) throws -> QueueTrack {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("airbridge-test-\(UUID().uuidString).mp3")
        try Data([0]).write(to: url)
        return QueueTrack(
            id: UUID(),
            originalFilename: filename,
            stagedPath: url.path,
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )
    }
}
