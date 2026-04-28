import Foundation

enum MusicAirPlaySelectionMigration {
    static func displayName(fromLegacyID id: String) -> String {
        guard let closingBracket = id.firstIndex(of: "]") else {
            return id
        }
        return String(id[id.index(after: closingBracket)...])
    }

    static func migratedDeviceIDs(fromLegacyIDs legacyIDs: [String], devices: [MusicAirPlayDevice]) -> [String] {
        let names = Set(legacyIDs.map(displayName(fromLegacyID:)))
        return devices
            .filter { device in
                names.contains(device.name)
                    && device.available
                    && device.supportsAudio
                    && device.kind.lowercased() == "homepod"
            }
            .map(\.id)
    }
}
