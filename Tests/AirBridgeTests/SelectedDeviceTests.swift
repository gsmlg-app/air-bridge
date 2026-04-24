import XCTest
@testable import AirBridge

final class SelectedDeviceTests: XCTestCase {
    func testCodableRoundtrip() throws {
        let original = SelectedDevice(id: "homepod.local", displayName: "HomePod", status: .error(reason: "timeout"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SelectedDevice.self, from: data)
        XCTAssertEqual(original, decoded)
        if case .error(let reason) = decoded.status {
            XCTAssertEqual(reason, "timeout")
        } else {
            XCTFail("Wrong status")
        }
    }
}
