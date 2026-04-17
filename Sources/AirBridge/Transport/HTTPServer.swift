import Hummingbird
import os

func buildApplication(
    engine: PlaybackEngine,
    queue: PlaybackQueue,
    appState: AppState?,
    address: String,
    port: Int,
    authToken: String
) throws -> some ApplicationProtocol {
    let router = buildRouter(engine: engine, queue: queue, appState: appState, authToken: authToken)
    let app = Application(router: router, configuration: .init(address: .hostname(address, port: port)))
    Log.server.info("Server configured on \(address, privacy: .public):\(port)")
    return app
}
