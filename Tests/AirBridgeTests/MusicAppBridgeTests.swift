import Foundation
import Testing
@testable import AirBridge

struct MusicAppBridgeTests {
    @Test func parseDevices_keepsAudioAirPlayDevicesAndSkipsComputer() throws {
        let output = """
        0000000000000000\tJonathan's MacBook Pro\tcomputer\ttrue\tfalse\ttrue\tfalse
        00003EB196898E74\tBedroom\tHomePod\ttrue\tfalse\ttrue\ttrue
        00004E5D4DE0B917\tElectrical Center\tHomePod\ttrue\ttrue\ttrue\ttrue
        0000560D47893FBF\tLiving Room\tApple TV\ttrue\tfalse\ttrue\ttrue
        """

        let devices = MusicAppBridge.parseDevices(output)

        #expect(devices.map(\.id) == [
            "00003EB196898E74",
            "00004E5D4DE0B917",
            "0000560D47893FBF",
        ])
        #expect(devices[1].name == "Electrical Center")
        #expect(devices[1].selected)
    }

    @Test func playScriptTargetsAllSelectedDeviceIDs() {
        let script = MusicAppBridge.playScript(
            fileURL: URL(fileURLWithPath: #"/tmp/voice "sample".mp3"#),
            deviceIDs: ["00003EB196898E74", "00004E5D4DE0B917"]
        )

        #expect(script.contains(#"set wantedIDs to {"00003EB196898E74", "00004E5D4DE0B917"}"#))
        #expect(script.contains("set current AirPlay devices to targetDevices"))
        #expect(script.contains(#"play POSIX file "/tmp/voice \"sample\".mp3" once true"#))
    }
}
