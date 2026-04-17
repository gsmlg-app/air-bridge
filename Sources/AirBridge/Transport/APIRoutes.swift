import Foundation
import Hummingbird
import os

// MARK: - Auth Middleware

struct AuthMiddleware: RouterMiddleware {
    let token: String

    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let auth = request.headers[.authorization] else {
            Log.http.warning("Missing auth token")
            return try jsonResponse(ErrorResponse(error: "unauthorized", message: "Missing auth token"), status: .unauthorized)
        }
        guard auth == "Bearer \(token)" else {
            Log.http.warning("Invalid auth token")
            return try jsonResponse(ErrorResponse(error: "unauthorized", message: "Invalid auth token"), status: .unauthorized)
        }
        return try await next(request, context)
    }
}

// MARK: - Router

func buildRouter(
    engine: PlaybackEngine,
    queue: PlaybackQueue,
    appState: AppState?,
    authToken: String = ""
) -> Router<BasicRequestContext> {
    let router = Router()

    if !authToken.isEmpty {
        router.add(middleware: AuthMiddleware(token: authToken))
    }

    // GET /status
    router.get("status") { _, _ -> Response in
        let engineState = await engine.state
        let queueState = await queue.list()
        let engineUID = await engine.outputDeviceUID

        let track: StatusResponse.TrackRef? = queueState.currentTrack.map {
            .init(id: $0.id.uuidString, filename: $0.originalFilename)
        }

        let defaultUID = AudioDeviceManager.deviceUID(for: AudioDeviceManager.getDefaultOutputDeviceID())
        let devices = AudioDeviceManager.allOutputDevices(engineTargetUID: engineUID)
        let engineDevice = devices.first { $0.isEngineTarget }
        let defaultDevice = devices.first { $0.isSystemDefault }
        let airplayRoute: String? = defaultDevice?.transport == .airplay ? defaultDevice?.name : nil

        let resp = StatusResponse(
            status: engineState.statusString,
            track: track,
            queue_length: queueState.tracks.count,
            queue_position: queueState.currentIndex,
            output: StatusResponse.OutputInfo(
                engine_target: engineUID,
                engine_target_name: engineDevice?.name,
                system_default: defaultUID,
                airplay_route: airplayRoute
            ),
            error: engineState.errorMessage
        )
        return try jsonResponse(resp)
    }

    // POST /queue — enqueue via multipart
    router.post("queue") { request, context -> Response in
        do {
            let upload = try await MultipartFileParser.extractFile(from: request)

            let ext = (upload.filename as NSString).pathExtension.lowercased()
            guard AudioValidator.supportedExtensions.contains(ext) else {
                return try jsonResponse(
                    ErrorResponse(error: "unsupported_format", message: "Unsupported format: \(ext)"),
                    status: .badRequest
                )
            }

            let (url, id) = try FileStaging.stage(data: upload.data, filename: upload.filename)
            let track = QueueTrack(
                id: id,
                originalFilename: upload.filename,
                stagedPath: url.path,
                addedAt: Date(),
                mimeType: upload.contentType
            )

            let (_, position) = await queue.enqueue(track: track)
            let queueState = await queue.list()

            return try jsonResponse(EnqueueResponse(
                id: id.uuidString,
                filename: upload.filename,
                position: position,
                queue_length: queueState.tracks.count
            ))
        } catch let error as MultipartUploadError {
            return try jsonResponse(
                ErrorResponse(error: error.errorCode, message: "\(error)"),
                status: .badRequest
            )
        }
    }

    // POST /play — upload and play immediately
    router.post("play") { request, context -> Response in
        do {
            let upload = try await MultipartFileParser.extractFile(from: request)

            let ext = (upload.filename as NSString).pathExtension.lowercased()
            guard AudioValidator.supportedExtensions.contains(ext) else {
                return try jsonResponse(
                    ErrorResponse(error: "unsupported_format", message: "Unsupported format: \(ext)"),
                    status: .badRequest
                )
            }

            let (url, id) = try FileStaging.stage(data: upload.data, filename: upload.filename)
            let track = QueueTrack(
                id: id,
                originalFilename: upload.filename,
                stagedPath: url.path,
                addedAt: Date(),
                mimeType: upload.contentType
            )

            await queue.playNow(track: track)
            let queueState = await queue.list()

            return try jsonResponse(PlayNowResponse(
                id: id.uuidString,
                filename: upload.filename,
                status: "playing",
                queue_length: queueState.tracks.count
            ))
        } catch let error as MultipartUploadError {
            return try jsonResponse(
                ErrorResponse(error: error.errorCode, message: "\(error)"),
                status: .badRequest
            )
        }
    }

    // GET /queue
    router.get("queue") { _, _ -> Response in
        let queueState = await queue.list()
        let tracks = queueState.tracks.enumerated().map { (idx, track) -> QueueListResponse.TrackInfo in
            let status: String
            if let current = queueState.currentIndex {
                if idx < current { status = "played" }
                else if idx == current { status = "playing" }
                else { status = "queued" }
            } else {
                status = "queued"
            }
            return QueueListResponse.TrackInfo(
                id: track.id.uuidString,
                filename: track.originalFilename,
                position: idx,
                status: status
            )
        }
        return try jsonResponse(QueueListResponse(current_index: queueState.currentIndex, tracks: tracks))
    }

    // DELETE /queue/:id
    router.delete("queue/:id") { _, context -> Response in
        guard let idString = context.parameters.get("id"),
              let id = UUID(uuidString: idString) else {
            return try jsonResponse(
                ErrorResponse(error: "invalid_id", message: "Invalid track ID"),
                status: .badRequest
            )
        }
        let removed = await queue.remove(id: id)
        guard removed else {
            return try jsonResponse(
                ErrorResponse(error: "not_found", message: "Track not found"),
                status: .notFound
            )
        }
        let queueState = await queue.list()
        return try jsonResponse(RemoveResponse(removed: idString, queue_length: queueState.tracks.count))
    }

    // POST /queue/next
    router.post("queue/next") { _, _ -> Response in
        guard let track = await queue.next() else {
            return try jsonResponse(
                ErrorResponse(error: "queue_end", message: "No next track"),
                status: .badRequest
            )
        }
        return try jsonResponse(TrackActionResponse(
            status: "playing",
            track: .init(id: track.id.uuidString, filename: track.originalFilename)
        ))
    }

    // POST /queue/prev
    router.post("queue/prev") { _, _ -> Response in
        guard let track = await queue.previous() else {
            return try jsonResponse(
                ErrorResponse(error: "queue_empty", message: "Queue is empty"),
                status: .badRequest
            )
        }
        return try jsonResponse(TrackActionResponse(
            status: "playing",
            track: .init(id: track.id.uuidString, filename: track.originalFilename)
        ))
    }

    // POST /queue/move
    router.post("queue/move") { request, context -> Response in
        struct MoveRequest: Decodable {
            let id: String
            let position: Int
        }
        let body = try await request.decode(as: MoveRequest.self, context: context)
        guard let trackID = UUID(uuidString: body.id) else {
            return try jsonResponse(
                ErrorResponse(error: "invalid_id", message: "Invalid track ID"),
                status: .badRequest
            )
        }
        do {
            try await queue.move(id: trackID, toPosition: body.position)
            return try jsonResponse(["status": "ok"])
        } catch {
            return try jsonResponse(
                ErrorResponse(error: "not_found", message: "Track not found"),
                status: .notFound
            )
        }
    }

    // POST /pause
    router.post("pause") { _, _ -> Response in
        let state = await engine.pause()
        return try jsonResponse(["status": state.statusString])
    }

    // POST /resume
    router.post("resume") { _, _ -> Response in
        let state = await engine.resume()
        return try jsonResponse(["status": state.statusString])
    }

    // POST /stop
    router.post("stop") { _, _ -> Response in
        await queue.clear()
        return try jsonResponse(["status": "idle"])
    }

    // GET /outputs
    router.get("outputs") { _, _ -> Response in
        let engineUID = await engine.outputDeviceUID
        let devices = AudioDeviceManager.allOutputDevices(engineTargetUID: engineUID)
        let defaultUID = AudioDeviceManager.deviceUID(for: AudioDeviceManager.getDefaultOutputDeviceID())
        let defaultDevice = devices.first { $0.isSystemDefault }
        let airplayRoute: String? = defaultDevice?.transport == .airplay ? defaultDevice?.name : nil

        return try jsonResponse(OutputsResponse(
            current_engine_target: engineUID,
            current_system_default: defaultUID,
            current_airplay_route: airplayRoute,
            devices: devices
        ))
    }

    // GET /outputs/current
    router.get("outputs/current") { _, _ -> Response in
        let engineUID = await engine.outputDeviceUID
        guard let uid = engineUID else {
            let defaultID = AudioDeviceManager.getDefaultOutputDeviceID()
            let defaultUID = AudioDeviceManager.deviceUID(for: defaultID) ?? ""
            let devices = AudioDeviceManager.allOutputDevices()
            let dev = devices.first { $0.isSystemDefault }
            return try jsonResponse(OutputCurrentResponse(
                id: defaultUID,
                name: dev?.name ?? "Unknown",
                transport: dev?.transport.rawValue ?? "other",
                hot_swapped: nil
            ))
        }
        let devices = AudioDeviceManager.allOutputDevices(engineTargetUID: uid)
        let dev = devices.first { $0.id == uid }
        return try jsonResponse(OutputCurrentResponse(
            id: uid,
            name: dev?.name ?? "Unknown",
            transport: dev?.transport.rawValue ?? "other",
            hot_swapped: nil
        ))
    }

    // PUT /outputs/current
    router.put("outputs/current") { request, context -> Response in
        struct SetOutputRequest: Decodable {
            let id: String
        }
        let body = try await request.decode(as: SetOutputRequest.self, context: context)

        do {
            let hotSwapped = try await engine.setOutputDevice(uid: body.id)

            if appState != nil {
                await MainActor.run {
                    UserDefaults.standard.set(body.id, forKey: "engineOutputDeviceUID")
                }
            }

            let devices = AudioDeviceManager.allOutputDevices(engineTargetUID: body.id)
            let dev = devices.first { $0.id == body.id }

            return try jsonResponse(OutputCurrentResponse(
                id: body.id,
                name: dev?.name ?? "Unknown",
                transport: dev?.transport.rawValue ?? "other",
                hot_swapped: hotSwapped
            ))
        } catch PlaybackEngineError.deviceNotFound {
            return try jsonResponse(
                ErrorResponse(error: "device_not_found", message: "Device not found: \(body.id)"),
                status: .notFound
            )
        } catch PlaybackEngineError.deviceUnavailable {
            return try jsonResponse(
                ErrorResponse(error: "device_unavailable", message: "Device unavailable: \(body.id)"),
                status: .badRequest
            )
        }
    }

    return router
}

// MARK: - Helpers

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: .init(data: data))
    )
}

// MARK: - Test Application

func buildTestApplication(
    engine: PlaybackEngine,
    queue: PlaybackQueue? = nil,
    authToken: String = ""
) throws -> some ApplicationProtocol {
    let q = queue ?? PlaybackQueue(engine: engine)
    let router = buildRouter(engine: engine, queue: q, appState: nil, authToken: authToken)
    return Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
}
