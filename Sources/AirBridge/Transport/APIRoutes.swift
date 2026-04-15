import Foundation
import Hummingbird

func buildRouter(engine: PlaybackEngine, appState: AppState?) -> Router<BasicRequestContext> {
    let router = Router(context: BasicRequestContext.self)

    // GET /status
    router.get("/status") { request, context -> Response in
        let state = await engine.state
        let route: String? = await MainActor.run { appState?.currentRoute }
        let statusResponse = StatusResponse(state: state, route: route)
        return try jsonResponse(statusResponse)
    }

    // POST /play
    router.post("/play") { request, context -> Response in
        let playRequest: PlayRequest
        do {
            let data = Data(buffer: try await request.body.collect(upTo: .max))
            playRequest = try JSONDecoder().decode(PlayRequest.self, from: data)
        } catch {
            let errResponse = ErrorResponse(error: "invalid_request", message: "Invalid JSON body")
            return try jsonResponse(errResponse, status: .badRequest)
        }

        do {
            let resultState = try await engine.play(path: playRequest.path)
            let file = resultState.currentFile ?? playRequest.path
            let playResponse = PlayResponse(status: resultState.statusString, file: file)
            return try jsonResponse(playResponse)
        } catch let error as AudioValidationError {
            let errResponse = ErrorResponse(error: error.errorCode, message: error.errorDescription)
            return try jsonResponse(errResponse, status: .badRequest)
        } catch {
            let errResponse = ErrorResponse(error: "playback_error", message: error.localizedDescription)
            return try jsonResponse(errResponse, status: .badRequest)
        }
    }

    // POST /stop
    router.post("/stop") { request, context -> Response in
        let _ = await engine.stop()
        let stopResponse = StopResponse(status: "idle")
        return try jsonResponse(stopResponse)
    }

    return router
}

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(
        status: status,
        headers: headers,
        body: .init(byteBuffer: ByteBuffer(data: data))
    )
}

func buildTestApplication(engine: PlaybackEngine) throws -> some ApplicationProtocol {
    let router = buildRouter(engine: engine, appState: nil)
    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: 0))
    )
}
