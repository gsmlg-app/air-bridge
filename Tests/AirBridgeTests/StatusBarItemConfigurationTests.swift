import AppKit
import Testing
@testable import AirBridge

struct StatusBarItemConfigurationTests {
    @Test func statusBarItemIsIconOnly() {
        #expect(StatusBarItemConfiguration.statusItemLength == NSStatusItem.squareLength)
        #expect(StatusBarItemConfiguration.buttonTitle == "")
        #expect(StatusBarItemConfiguration.imagePosition == .imageOnly)
    }
}
