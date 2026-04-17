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

// MARK: - Queue and Output Device Types

struct QueueTrack: Identifiable, Sendable, Equatable {
    let id: UUID
    let originalFilename: String
    let stagedPath: String
    let addedAt: Date
    let mimeType: String?
}

struct QueueState: Sendable, Equatable {
    var tracks: [QueueTrack]
    var currentIndex: Int?

    init(tracks: [QueueTrack] = [], currentIndex: Int? = nil) {
        self.tracks = tracks
        self.currentIndex = currentIndex
    }

    var currentTrack: QueueTrack? {
        guard let idx = currentIndex, tracks.indices.contains(idx) else { return nil }
        return tracks[idx]
    }

    var isEmpty: Bool { tracks.isEmpty }
}

enum AudioTransport: String, Sendable, Codable {
    case builtIn = "built_in"
    case usb
    case bluetooth
    case hdmi
    case airplay
    case virtual
    case other
}

struct AudioOutputDeviceInfo: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let name: String
    let transport: AudioTransport
    let isSystemDefault: Bool
    let isEngineTarget: Bool
}

// MARK: - Error Response (unchanged)

struct ErrorResponse: Codable, Sendable {
    let error: String
    let message: String
}

// MARK: - v2 API DTOs

struct EnqueueResponse: Codable, Sendable {
    let id: String
    let filename: String
    let position: Int
    let queue_length: Int
}

struct PlayNowResponse: Codable, Sendable {
    let id: String
    let filename: String
    let status: String
    let queue_length: Int
}

struct QueueListResponse: Codable, Sendable {
    let current_index: Int?
    let tracks: [TrackInfo]

    struct TrackInfo: Codable, Sendable {
        let id: String
        let filename: String
        let position: Int
        let status: String
    }
}

struct TrackActionResponse: Codable, Sendable {
    let status: String
    let track: TrackRef?

    struct TrackRef: Codable, Sendable {
        let id: String
        let filename: String
    }
}

struct RemoveResponse: Codable, Sendable {
    let removed: String
    let queue_length: Int
}

struct OutputsResponse: Codable, Sendable {
    let current_engine_target: String?
    let current_system_default: String?
    let current_airplay_route: String?
    let devices: [AudioOutputDeviceInfo]
}

struct OutputCurrentResponse: Codable, Sendable {
    let id: String
    let name: String
    let transport: String
    let hot_swapped: Bool?
}

struct StatusResponse: Codable, Sendable {
    let status: String
    let track: TrackRef?
    let queue_length: Int
    let queue_position: Int?
    let output: OutputInfo?
    let error: String?

    struct TrackRef: Codable, Sendable {
        let id: String
        let filename: String
    }

    struct OutputInfo: Codable, Sendable {
        let engine_target: String?
        let engine_target_name: String?
        let system_default: String?
        let airplay_route: String?
    }
}
