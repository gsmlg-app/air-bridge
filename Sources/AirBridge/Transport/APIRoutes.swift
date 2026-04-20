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
    discovery: BonjourDiscovery?,
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
        let selected = await engine.currentDevice

        let track: StatusResponse.TrackRef? = queueState.currentTrack.map {
            .init(id: $0.id.uuidString, filename: $0.originalFilename)
        }

        let resp = StatusResponse(
            status: engineState.statusString,
            track: track,
            queue_length: queueState.tracks.count,
            queue_position: queueState.currentIndex,
            output: StatusResponse.OutputInfo(
                airplay_device_id: selected?.id,
                airplay_device_name: selected?.displayName
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

    // GET /outputs — list discovered AirPlay devices
    router.get("outputs") { _, _ -> Response in
        let devices = await discovery?.devices ?? []
        let selectedID = await engine.currentDevice?.id
        let infos = devices.map { d in
            AirPlayDeviceInfo(
                id: d.id,
                name: d.displayName,
                model: d.modelID,
                supports_airplay_2: d.supportsAirPlay2,
                requires_pairing: d.requiresPairing,
                is_selected: d.id == selectedID
            )
        }
        let selected = infos.first { $0.is_selected }
        return try jsonResponse(OutputsResponse(selected: selected, devices: infos))
    }

    // GET /outputs/current — currently-selected AirPlay device
    router.get("outputs/current") { _, _ -> Response in
        guard let device = await engine.currentDevice else {
            return try jsonResponse(
                ErrorResponse(error: "none_selected", message: "No AirPlay device selected"),
                status: .notFound
            )
        }
        return try jsonResponse(OutputCurrentResponse(
            id: device.id,
            name: device.displayName,
            model: device.modelID,
            supports_airplay_2: device.supportsAirPlay2
        ))
    }

    // PUT /outputs/current — select an AirPlay device by Bonjour id
    router.put("outputs/current") { request, context -> Response in
        struct SetOutputRequest: Decodable {
            let id: String
        }
        let body = try await request.decode(as: SetOutputRequest.self, context: context)
        let devices = await discovery?.devices ?? []
        guard let device = devices.first(where: { $0.id == body.id }) else {
            return try jsonResponse(
                ErrorResponse(error: "device_not_found", message: "No AirPlay device with id: \(body.id)"),
                status: .notFound
            )
        }
        if let appState = appState {
            await appState.selectAirPlayDevice(device)
        } else {
            await engine.setDevice(device)
        }
        return try jsonResponse(OutputCurrentResponse(
            id: device.id,
            name: device.displayName,
            model: device.modelID,
            supports_airplay_2: device.supportsAirPlay2
        ))
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
    let router = buildRouter(engine: engine, queue: q, discovery: nil, appState: nil, authToken: authToken)
    return Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
}
