import Testing
@testable import AirBridge

struct PlaybackStateTests {
    @Test func idleState_isNotPlaying() {
        let state = PlaybackState.idle
        #expect(!state.isPlaying)
        #expect(state.statusString == "idle")
    }

    @Test func playingState_isPlaying() {
        let state = PlaybackState.playing(file: "test.mp3")
        #expect(state.isPlaying)
        #expect(state.currentFile == "test.mp3")
    }

    @Test func errorState_hasMessage() {
        let state = PlaybackState.error(message: "fail")
        #expect(state.errorMessage == "fail")
        #expect(state.statusString == "error")
    }

    @Test func queueTrack_equatable() {
        let id = UUID()
        let t1 = QueueTrack(id: id, originalFilename: "a.mp3", stagedPath: "/tmp/a", addedAt: Date(), mimeType: "audio/mpeg")
        let t2 = QueueTrack(id: id, originalFilename: "a.mp3", stagedPath: "/tmp/a", addedAt: t1.addedAt, mimeType: "audio/mpeg")
        #expect(t1 == t2)
    }

    @Test func queueState_currentTrack() {
        let track = QueueTrack(id: UUID(), originalFilename: "a.mp3", stagedPath: "/tmp/a", addedAt: Date(), mimeType: nil)
        var state = QueueState(tracks: [track], currentIndex: 0)
        #expect(state.currentTrack?.id == track.id)
        state.currentIndex = nil
        #expect(state.currentTrack == nil)
    }

    @Test func queueState_empty() {
        let state = QueueState()
        #expect(state.isEmpty)
        #expect(state.currentTrack == nil)
    }

    @Test func audioTransport_rawValues() {
        #expect(AudioTransport.builtIn.rawValue == "built_in")
        #expect(AudioTransport.airplay.rawValue == "airplay")
    }

    @Test func enqueueResponse_encodesToJSON() throws {
        let resp = EnqueueResponse(id: "abc", filename: "test.mp3", position: 0, queue_length: 1)
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(EnqueueResponse.self, from: data)
        #expect(decoded.id == "abc")
        #expect(decoded.queue_length == 1)
    }
}
