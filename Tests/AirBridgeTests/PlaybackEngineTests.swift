import XCTest
@testable import AirBridge

final class PlaybackEngineTests: XCTestCase {
    func testInitialState() async {
        let engine = PlaybackEngine()
        let selected = await engine.selectedDevices()
        XCTAssertTrue(selected.isEmpty)
        let current = await engine.currentDevice
        XCTAssertNil(current)
    }

    func testSetSelectedDevices() async {
        let engine = PlaybackEngine()
        let d1 = AirPlayDevice(id: "1", displayName: "One", serviceType: "_airplay._tcp.", txt: [:])

        await engine.setSelectedDevices([d1])
        let selected = await engine.selectedDevices()
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected[0].id, "1")
        // Since discovery is nil, connect() will fail immediately with .error
        // Wait a tick for the detached task to finish
        try? await Task.sleep(nanoseconds: 50_000_000)
        let updated = await engine.selectedDevices()
        if case .error = updated[0].status {
            // expected
        } else {
            XCTFail("Should have errored due to no discovery")
        }
    }
}
