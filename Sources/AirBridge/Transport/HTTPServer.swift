import Hummingbird

func buildApplication(engine: PlaybackEngine, appState: AppState?, address: String, port: Int, authToken: String) throws -> some ApplicationProtocol {
    let router = buildRouter(engine: engine, appState: appState, authToken: authToken)
    let app = Application(
        router: router,
        configuration: .init(address: .hostname(address, port: port))
    )
    Log.server.info("Server configured on \(address):\(port)")
    return app
}
