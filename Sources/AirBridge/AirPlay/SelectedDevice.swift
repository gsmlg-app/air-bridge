import Foundation

enum DeviceStatus: Sendable, Hashable, Codable, Equatable {
    case pairing
    case ok
    case offline
    case error(reason: String)
}

struct SelectedDevice: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let displayName: String
    var status: DeviceStatus
}
