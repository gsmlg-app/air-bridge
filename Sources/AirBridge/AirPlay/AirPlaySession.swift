import Foundation
import Network
import os

/// Owns the per-playback AirPlay session: picks up an `AirPlayDevice`, resolves
/// its `NWEndpoint` from the discovery actor, runs HAP transient pair-setup to
/// derive ChaCha20-Poly1305 keys, then (Phase 3+) uses those keys to drive RTSP
/// control and RTP audio.
///
/// Phase 2 lands HAP pairing. Phase 3 will add RTSP on top of the paired channel.
actor AirPlaySession {
    private let log = Logger(subsystem: "com.gsmlg.airbridge", category: "airplay")

    private weak var discovery: BonjourDiscovery?
    private var selectedDevice: AirPlayDevice?
    private var sessionKeys: HAPSessionKeys?

    var currentDevice: AirPlayDevice? { selectedDevice }
    var isPaired: Bool { sessionKeys != nil }

    func attachDiscovery(_ discovery: BonjourDiscovery) {
        self.discovery = discovery
    }

    /// Remember a device as the target. Does not open a network connection.
    /// Invalidates any existing session keys since they're device-specific.
    func setDevice(_ device: AirPlayDevice?) {
        self.selectedDevice = device
        self.sessionKeys = nil
        if let device {
            log.info("AirPlay target set: \(device.displayName, privacy: .public)")
        } else {
            log.info("AirPlay target cleared")
        }
    }

    /// Perform HAP transient pairing against the currently-selected device.
    /// Succeeds silently if already paired.
    func connect() async throws {
        guard let device = selectedDevice else {
            throw AirPlayError.noDeviceSelected
        }
        if sessionKeys != nil {
            return
        }
        guard let endpoint = await discovery?.endpoint(for: device.id) else {
            throw AirPlayError.deviceUnreachable("no Bonjour endpoint for \(device.id)")
        }
        log.info("Starting HAP pair-setup for \(device.displayName, privacy: .public)")
        let pairing = HAPPairing(endpoint: endpoint)
        do {
            self.sessionKeys = try await pairing.run()
            log.info("HAP pair-setup ok for \(device.displayName, privacy: .public)")
        } catch let pairingError as HAPPairing.PairingError {
            log.error("HAP pairing failed: \(String(describing: pairingError), privacy: .public)")
            throw AirPlayError.protocolError("pairing failed: \(pairingError)")
        }
    }

    /// Stream the audio at `fileURL` to the connected HomePod.
    /// Phase 2: after successful pairing this is where Phase 3 (RTSP) will go.
    func play(fileURL: URL) async throws {
        try await connect()
        // Phase 2 ends here. Phase 3 will open an encrypted RTSP control session.
        throw AirPlayError.notImplemented(phase: .rtsp)
    }

    /// Tear down the session.
    func stop() async {
        sessionKeys = nil
    }
}
