import Foundation
import os

/// Advertises the AirBridge HTTP server on the local network via mDNS
/// as `_air-bridge._tcp`. Clients can discover the service using Bonjour
/// (e.g., `dns-sd -B _air-bridge._tcp local.`).
@MainActor
final class ServiceAdvertiser {
    private var service: NetService?
    private var delegate: NetServiceLogger?

    /// Begin advertising on the given port.
    func start(port: UInt16) {
        stop()

        let service = NetService(
            domain: "local.",
            type: "_air-bridge._tcp.",
            name: "AirBridge",
            port: Int32(port)
        )
        let delegate = NetServiceLogger(port: port)
        service.includesPeerToPeer = true
        service.delegate = delegate
        service.publish()

        self.service = service
        self.delegate = delegate
    }

    /// Stop advertising.
    func stop() {
        service?.stop()
        service = nil
        delegate = nil
    }
}

private final class NetServiceLogger: NSObject, NetServiceDelegate {
    private let port: UInt16

    init(port: UInt16) {
        self.port = port
    }

    func netServiceDidPublish(_ sender: NetService) {
        Log.server.info("mDNS service registered: \(sender.name, privacy: .public) on port \(self.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        Log.server.error("ServiceAdvertiser failed: \(String(describing: errorDict), privacy: .public)")
    }

    func netServiceDidStop(_ sender: NetService) {
        Log.server.info("ServiceAdvertiser cancelled")
    }
}
