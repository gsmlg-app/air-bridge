import AVFoundation
import Foundation

enum OutputRoutingPolicy {
    static func restorablePinnedUID(
        from savedUID: String?,
        transportForUID: (String) -> AudioTransport?
    ) -> String? {
        guard let uid = savedUID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.isEmpty else {
            return nil
        }

        if transportForUID(uid) == .airplay {
            return nil
        }

        return uid
    }

    static func transportForUID(_ uid: String) -> AudioTransport? {
        guard let deviceID = AudioDeviceManager.deviceID(forUID: uid) else { return nil }
        return AudioDeviceManager.transportType(for: deviceID)
    }

    static func systemAirPlayRoutePickerPlayer(for player: AVPlayer) -> AVPlayer? {
        nil
    }
}
