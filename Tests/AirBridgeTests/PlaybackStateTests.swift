import Foundation
import Testing
@testable import AirBridge

@Test func idleState_isNotPlaying() {
    let state = PlaybackState.idle
    #expect(state.isPlaying == false)
}

@Test func playingState_isPlaying() {
    let state = PlaybackState.playing(file: "/tmp/test.mp3")
    #expect(state.isPlaying == true)
}

@Test func statusResponse_fromIdleState() {
    let response = StatusResponse(state: .idle, route: nil)
    #expect(response.status == "idle")
    #expect(response.file == nil)
    #expect(response.error == nil)
}

@Test func statusResponse_fromPlayingState() {
    let response = StatusResponse(state: .playing(file: "/tmp/test.mp3"), route: "HomePod Kitchen")
    #expect(response.status == "playing")
    #expect(response.file == "/tmp/test.mp3")
    #expect(response.route == "HomePod Kitchen")
}

@Test func statusResponse_fromErrorState() {
    let response = StatusResponse(state: .error(message: "decode failed"), route: nil)
    #expect(response.status == "error")
    #expect(response.error == "decode failed")
}

@Test func playRequest_decodesFromJSON() throws {
    let json = #"{"path":"/tmp/reply.mp3"}"#
    let data = json.data(using: .utf8)!
    let request = try JSONDecoder().decode(PlayRequest.self, from: data)
    #expect(request.path == "/tmp/reply.mp3")
}

@Test func statusResponse_encodesToJSON() throws {
    let response = StatusResponse(state: .playing(file: "/tmp/test.mp3"), route: nil)
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(StatusResponse.self, from: data)
    #expect(decoded.status == "playing")
    #expect(decoded.file == "/tmp/test.mp3")
}
