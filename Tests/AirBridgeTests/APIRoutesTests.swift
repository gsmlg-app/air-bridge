import Testing
import Hummingbird
import HummingbirdTesting
import Foundation
@testable import AirBridge

@Test func statusEndpoint_returnsIdleByDefault() async throws {
    let engine = PlaybackEngine()
    let app = try buildTestApplication(engine: engine)
    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/status", method: .get)
        #expect(response.status == .ok)
        let data = Data(buffer: response.body)
        let body = try JSONDecoder().decode(StatusResponse.self, from: data)
        #expect(body.status == "idle")
    }
}

@Test func playEndpoint_invalidPath_returns400() async throws {
    let engine = PlaybackEngine()
    let app = try buildTestApplication(engine: engine)
    try await app.test(.router) { client in
        let payload = #"{"path":"/nonexistent/file.mp3"}"#
        let response = try await client.execute(
            uri: "/play",
            method: .post,
            headers: [.contentType: "application/json"],
            body: ByteBuffer(string: payload)
        )
        #expect(response.status == .badRequest)
        let data = Data(buffer: response.body)
        let body = try JSONDecoder().decode(ErrorResponse.self, from: data)
        #expect(body.error == "file_not_found")
    }
}

@Test func stopEndpoint_returnsIdleStatus() async throws {
    let engine = PlaybackEngine()
    let app = try buildTestApplication(engine: engine)
    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/stop", method: .post)
        #expect(response.status == .ok)
        let data = Data(buffer: response.body)
        let body = try JSONDecoder().decode(StopResponse.self, from: data)
        #expect(body.status == "idle")
    }
}
