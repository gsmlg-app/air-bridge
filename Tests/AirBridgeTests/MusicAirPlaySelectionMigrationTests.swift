import Testing
@testable import AirBridge

struct MusicAirPlaySelectionMigrationTests {
    @Test func displayNameDropsBonjourPrefix() {
        let name = MusicAirPlaySelectionMigration.displayName(fromLegacyID: "[_airplay._tcp]Bedroom")

        #expect(name == "Bedroom")
    }

    @Test func migratedDeviceIDsMatchAvailableDevicesByDisplayName() {
        let devices = [
            MusicAirPlayDevice(id: "old-electrical", name: "Electrical Center", kind: "HomePod", available: false, selected: false, supportsAudio: true, isProtected: false),
            MusicAirPlayDevice(id: "bedroom", name: "Bedroom", kind: "HomePod", available: true, selected: false, supportsAudio: true, isProtected: true),
            MusicAirPlayDevice(id: "electrical", name: "Electrical Center", kind: "HomePod", available: true, selected: false, supportsAudio: true, isProtected: true),
        ]

        let ids = MusicAirPlaySelectionMigration.migratedDeviceIDs(
            fromLegacyIDs: ["[_airplay._tcp]Bedroom", "[_airplay._tcp]Electrical Center"],
            devices: devices
        )

        #expect(ids == ["bedroom", "electrical"])
    }
}
