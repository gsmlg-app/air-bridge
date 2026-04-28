import XCTest
@testable import AirBridge

final class AirPlayErrorTests: XCTestCase {
    func testAirPlayErrorLocalizedDescriptionUsesReadableMessage() {
        let error = AirPlayError.protocolError("pairing failed: accessory error: accessory requested backoff; wait before retrying")

        XCTAssertEqual(
            error.localizedDescription,
            "AirPlay protocol error: pairing failed: accessory error: accessory requested backoff; wait before retrying"
        )
    }

    func testPairingErrorLocalizedDescriptionIncludesAccessoryError() {
        let error = HAPPairing.PairingError.accessoryError(.backoff)

        XCTAssertEqual(
            error.localizedDescription,
            "accessory error: accessory requested backoff; wait before retrying"
        )
    }

    func testPairingErrorExplainsForbiddenPairingResponse() {
        let error = HAPPairing.PairingError.httpError(403, "")

        XCTAssertEqual(
            error.localizedDescription,
            "HTTP 403 Forbidden from AirPlay receiver; pairing is disabled or this receiver rejected AirBridge"
        )
    }

    func testMacAirPlayReceiverIsUnsupportedTarget() {
        let device = AirPlayDevice(
            id: "mac",
            displayName: "MacBook",
            serviceType: "_airplay._tcp.",
            txt: ["model": "Mac16,12"]
        )

        XCTAssertFalse(device.isSupportedTarget)
        XCTAssertEqual(
            device.unsupportedTargetReason,
            "Mac AirPlay Receiver is not supported. Select a HomePod or Apple TV."
        )
    }
}
