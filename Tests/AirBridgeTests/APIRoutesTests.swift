import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import AirBridge

struct APIRoutesTests {
    @Test func statusEndpoint_returnsIdleByDefault() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/status", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"status\":\"idle\""))
            }
        }
    }

    @Test func stopEndpoint_returnsIdle() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/stop", method: .post) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"status\":\"idle\""))
            }
        }
    }

    @Test func queueEndpoint_returnsEmptyQueue() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/queue", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"tracks\":[]"))
            }
        }
    }

    @Test func outputsEndpoint_returnsCoreAudioOutputState() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/outputs", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"devices\""))
                #expect(body.contains("\"current_engine_target\""))
                #expect(body.contains("\"current_system_default\""))
                #expect(!body.contains("\"requires_pairing\""))
                #expect(!body.contains("\"selected_devices\""))
            }
        }
    }

    @Test func outputsCurrentEndpoint_noPinnedDevice_returnsSystemDefault() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/outputs/current", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"hot_swapped\":null"))
            }
        }
    }

    @Test func deleteQueueTrack_notFound() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(
                uri: "/queue/\(UUID().uuidString)",
                method: .delete
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test func pauseEndpoint_returnsStatus() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/pause", method: .post) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test func authEnabled_validToken_returns200() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine(), authToken: "secret")
        try await app.test(.live) { client in
            try await client.execute(
                uri: "/status",
                method: .get,
                headers: [.authorization: "Bearer secret"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test func authEnabled_missingToken_returns401() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine(), authToken: "secret")
        try await app.test(.live) { client in
            try await client.execute(uri: "/status", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func authEnabled_wrongToken_returns401() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine(), authToken: "secret")
        try await app.test(.live) { client in
            try await client.execute(
                uri: "/status",
                method: .get,
                headers: [.authorization: "Bearer wrong"]
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func queueEndpoint_oversizedMultipartMetadataReturnsContentTooLarge() async throws {
        let boundary = "AirBridgeRouteMetadataBoundary"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"metadata.txt\"\r\n".utf8))
        body.append(Data("X-AirBridge-Metadata: \(String(repeating: "x", count: 17 * 1024))\r\n\r\n".utf8))
        body.append(Data([0x01]))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let requestBody = body

        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(
                uri: "/queue",
                method: .post,
                headers: [.contentType: "multipart/form-data; boundary=\(boundary)"],
                body: ByteBuffer(data: requestBody)
            ) { response in
                #expect(response.status == .contentTooLarge)
                let responseBody = String(buffer: response.body)
                #expect(responseBody.contains("\"error\":\"multipart_metadata_too_large\""))
                #expect(responseBody.contains("Multipart metadata exceeds"))
            }
        }
    }

    @Test func queueEndpoint_malformedMultipartReturnsBadRequest() async throws {
        let boundary = "AirBridgeRouteMalformedBoundary"
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Invalid Header: value\r\n\r\n".utf8))
        body.append(Data([0x01]))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let requestBody = body

        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(
                uri: "/queue",
                method: .post,
                headers: [.contentType: "multipart/form-data; boundary=\(boundary)"],
                body: ByteBuffer(data: requestBody)
            ) { response in
                #expect(response.status == .badRequest)
                let responseBody = String(buffer: response.body)
                #expect(responseBody.contains("\"error\":\"malformed_multipart\""))
            }
        }
    }
}
