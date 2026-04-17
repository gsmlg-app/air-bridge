import Foundation
import Testing
@testable import AirBridge

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

    @Test func list_returnsCurrentState() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let state = await queue.list()
        #expect(state.isEmpty)
        #expect(state.currentIndex == nil)
    }
}
