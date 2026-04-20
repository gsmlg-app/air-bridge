import Foundation

enum AirPlayError: Error, Sendable, CustomStringConvertible {
    enum Phase: String, Sendable {
        case pairing
        case rtsp
        case encoding
        case streaming
    }

    case notImplemented(phase: Phase)
    case noDeviceSelected
    case deviceUnknown(id: String)
    case deviceUnreachable(String)
    case protocolError(String)

    var description: String {
        switch self {
        case .notImplemented(let phase):
            return "AirPlay \(phase.rawValue) is not implemented yet."
        case .noDeviceSelected:
            return "No AirPlay device selected. Open Settings and tick a HomePod."
        case .deviceUnknown(let id):
            return "AirPlay device \(id) is not in the current discovered set."
        case .deviceUnreachable(let message):
            return "AirPlay device unreachable: \(message)"
        case .protocolError(let message):
            return "AirPlay protocol error: \(message)"
        }
    }
}
