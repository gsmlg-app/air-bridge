import AVFoundation
import Testing
@testable import AirBridge

struct OutputRoutingPolicyTests {
    @Test func savedAirPlayPinIsNotRestored() {
        let restored = OutputRoutingPolicy.restorablePinnedUID(
            from: "homepod-uid",
            transportForUID: { _ in .airplay }
        )

        #expect(restored == nil)
    }

    @Test func savedLocalPinCanBeRestored() {
        let restored = OutputRoutingPolicy.restorablePinnedUID(
            from: "usb-uid",
            transportForUID: { _ in .usb }
        )

        #expect(restored == "usb-uid")
    }

    @Test func emptySavedPinIsNotRestored() {
        let restored = OutputRoutingPolicy.restorablePinnedUID(
            from: "",
            transportForUID: { _ in .builtIn }
        )

        #expect(restored == nil)
    }

    @Test func systemAirPlayPickerUsesSystemRouteInsteadOfPlayerScopedRoute() {
        let player = AVPlayer()

        let routePickerPlayer = OutputRoutingPolicy.systemAirPlayRoutePickerPlayer(for: player)

        #expect(routePickerPlayer == nil)
    }
}
