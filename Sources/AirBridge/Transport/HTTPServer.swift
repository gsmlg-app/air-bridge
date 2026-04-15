import Hummingbird

func buildApplication(engine: PlaybackEngine, appState: AppState?, port: Int) throws -> some ApplicationProtocol {
    let router = buildRouter(engine: engine, appState: appState)
    let app = Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: port))
    )
    Log.server.info("Server configured on 127.0.0.1:\(port)")
    return app
}
