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

struct SelectedDeviceInfo: Codable, Sendable {
    let id: String
    let name: String
    let status: String
    let status_reason: String?
    let online: Bool
}

struct AirPlayDeviceInfo: Codable, Sendable {
    let id: String
    let name: String
    let model: String?
    let supports_airplay_2: Bool
    let requires_pairing: Bool
    let is_supported_target: Bool
    let unsupported_reason: String?
    let is_selected: Bool
    let selected_order: Int?
}

struct OutputsResponse: Encodable, Sendable {
    let current_engine_target: String?
    let current_system_default: String?
    let current_airplay_route: String?
    let devices: [AudioOutputDeviceInfo]

    enum CodingKeys: String, CodingKey {
        case current_engine_target
        case current_system_default
        case current_airplay_route
        case devices
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(current_engine_target, forKey: .current_engine_target)
        try container.encode(current_system_default, forKey: .current_system_default)
        try container.encode(current_airplay_route, forKey: .current_airplay_route)
        try container.encode(devices, forKey: .devices)
    }
}

struct OutputCurrentResponse: Encodable, Sendable {
    let id: String
    let name: String
    let transport: String
    let hot_swapped: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case transport
        case hot_swapped
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(transport, forKey: .transport)
        try container.encode(hot_swapped, forKey: .hot_swapped)
    }
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
