import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var playbackState: PlaybackState = .idle
    @Published var currentRoute: String = "System Default"
    @Published var serverPort: Int = 9876

    let engine = PlaybackEngine()

    init() {
        Task {
            await engine.setStateCallback { [weak self] newState in
                Task { @MainActor in
                    self?.playbackState = newState
                }
            }
        }
    }

    func play(path: String) async throws {
        _ = try await engine.play(path: path)
    }

    func stop() async {
        _ = await engine.stop()
    }
}

extension AppState {
    func startServer() {
        Task.detached { [weak self] in
            guard let self else { return }
            let port = await self.serverPort
            let engine = await self.engine
            do {
                let app = try buildApplication(engine: engine, appState: self, port: port)
                Log.server.info("Starting server on 127.0.0.1:\(port)")
                try await app.runService()
            } catch {
                Log.server.error("Server failed to start: \(error)")
            }
        }
    }
}
