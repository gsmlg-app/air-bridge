import Foundation

enum PlaybackState: Sendable, Equatable {
    case idle
    case playing(file: String)
    case paused(file: String)
    case error(message: String)

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    var statusString: String {
        switch self {
        case .idle: "idle"
        case .playing: "playing"
        case .paused: "paused"
        case .error: "error"
        }
    }

    var currentFile: String? {
        switch self {
        case .playing(let file), .paused(let file): file
        default: nil
        }
    }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

struct PlayRequest: Decodable, Sendable {
    let path: String
}

struct PlayResponse: Codable, Sendable {
    let status: String
    let file: String
}

struct StopResponse: Codable, Sendable {
    let status: String
}

struct ErrorResponse: Codable, Sendable {
    let error: String
    let message: String
}

struct StatusResponse: Codable, Sendable {
    let status: String
    let file: String?
    let route: String?
    let error: String?

    init(state: PlaybackState, route: String?) {
        self.status = state.statusString
        self.file = state.currentFile
        self.route = route
        self.error = state.errorMessage
    }
}
