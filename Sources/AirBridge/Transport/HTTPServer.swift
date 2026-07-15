import Hummingbird
import NIOCore
import os

private let httpConnectionIdleTimeout: TimeAmount = .seconds(30)

func buildApplication(
    engine: PlaybackEngine,
    queue: PlaybackQueue,
    appState: AppState?,
    address: String,
    port: Int,
    authToken: String
) throws -> some ApplicationProtocol {
    let router = buildRouter(engine: engine, queue: queue, appState: appState, authToken: authToken)
    let app = Application(
        router: router,
        server: .http1(configuration: .init(idleTimeout: httpConnectionIdleTimeout)),
        configuration: .init(address: .hostname(address, port: port))
    )
    Log.server.info("Server configured on \(address, privacy: .public):\(port)")
    return app
}
