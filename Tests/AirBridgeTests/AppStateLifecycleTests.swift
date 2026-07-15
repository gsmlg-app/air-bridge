import Combine
import CoreAudio
import XCTest
@testable import AirBridge

private final class OutputDeviceListenerRegistry {
    var listener: AudioObjectPropertyListenerBlock?
    var removeCallCount = 0
}

@MainActor
final class AppStateLifecycleTests: XCTestCase {
    func testConcurrentRestartsLeaveOneStoppableServerRun() async throws {
        let defaults = UserDefaults.standard
        let previousAddress = defaults.object(forKey: "listenAddress")
        let previousPort = defaults.object(forKey: "serverPort")
        defaults.set("127.0.0.1", forKey: "listenAddress")
        defaults.set("0", forKey: "serverPort")
        defer {
            restore(previousAddress, forKey: "listenAddress", in: defaults)
            restore(previousPort, forKey: "serverPort", in: defaults)
        }

        let appState = AppState(startBackgroundWork: false)
        appState.startServer()

        async let firstRestart: UUID = appState.restartServer()
        async let secondRestart: UUID = appState.restartServer()
        let (firstRestartID, secondRestartID) = await (firstRestart, secondRestart)

        XCTAssertEqual(firstRestartID, secondRestartID)
        XCTAssertTrue(appState.serverRunning)

        await appState.stopServer()
        XCTAssertFalse(appState.serverRunning)

        appState.startServer()
        XCTAssertTrue(appState.serverRunning)
        await appState.stopServer()
    }

    func testPeriodicSyncTaskDoesNotKeepAppStateAlive() async throws {
        var appState: AppState? = AppState(startBackgroundWork: false)
        weak let weakAppState = appState
        appState?.startPeriodicStateSync()

        appState = nil
        for _ in 0..<20 where weakAppState != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(weakAppState)
    }

    func testPeriodicSyncDoesNotRepublishUnchangedState() async throws {
        let devices = [
            AudioOutputDeviceInfo(
                id: "stable-device",
                name: "Stable Output",
                transport: .builtIn,
                isSystemDefault: true,
                isEngineTarget: false
            ),
        ]
        var providerCallCount = 0
        let appState = AppState(
            startBackgroundWork: false,
            outputDeviceProvider: { _ in
                providerCallCount += 1
                return devices
            }
        )
        appState.refreshOutputDevices()
        var queueUpdates = 0
        var outputDeviceUpdates = 0
        var outputNameUpdates = 0
        let cancellables = [
            appState.$queueState.dropFirst().sink { _ in queueUpdates += 1 },
            appState.$outputDevices.dropFirst().sink { _ in outputDeviceUpdates += 1 },
            appState.$currentOutputName.dropFirst().sink { _ in outputNameUpdates += 1 },
        ]

        await appState.syncStateOnce()
        await appState.syncStateOnce()

        XCTAssertEqual(providerCallCount, 3)
        XCTAssertEqual(queueUpdates, 0)
        XCTAssertEqual(outputDeviceUpdates, 0)
        XCTAssertEqual(outputNameUpdates, 0)
        withExtendedLifetime(cancellables) {}
    }

    func testOutputDeviceObserverDoesNotRetainItself() {
        let registry = OutputDeviceListenerRegistry()
        weak var weakObserver: OutputDeviceObserver?

        autoreleasepool {
            let observer = OutputDeviceObserver(
                addListener: { _, listener in
                    registry.listener = listener.block
                    return noErr
                },
                removeListener: { _, _ in
                    registry.removeCallCount += 1
                    return noErr
                },
                onChange: { _ in XCTFail("Released observer received a callback") }
            )
            weakObserver = observer
        }

        XCTAssertNil(weakObserver)
        XCTAssertEqual(registry.removeCallCount, 1)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        withUnsafePointer(to: &address) { addresses in
            registry.listener?(1, addresses)
        }
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
