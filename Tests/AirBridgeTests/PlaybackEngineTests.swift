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
}
