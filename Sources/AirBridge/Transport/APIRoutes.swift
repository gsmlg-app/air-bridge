import Foundation
import Hummingbird

// MARK: - Auth Middleware

struct AuthMiddleware: RouterMiddleware {
    let token: String

    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let auth = request.headers[.authorization],
              auth == "Bearer \(token)" else {
            Log.http.warning("Unauthorized request to \(request.uri.path)")
            return try jsonResponse(
                ErrorResponse(error: "unauthorized", message: "Invalid or missing auth token"),
                status: .unauthorized
            )
        }
        return try await next(request, context)
    }
}

// MARK: - Router

func buildRouter(engine: PlaybackEngine, appState: AppState?, authToken: String = "") -> Router<BasicRequestContext> {
    let router = Router(context: BasicRequestContext.self)

    if !authToken.isEmpty {
        router.addMiddleware {
            AuthMiddleware(token: authToken)
        }
    }

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

// MARK: - Helpers

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

func buildTestApplication(engine: PlaybackEngine, authToken: String = "") throws -> some ApplicationProtocol {
    let router = buildRouter(engine: engine, appState: nil, authToken: authToken)
    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: 0))
    )
}
