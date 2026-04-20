import Foundation
import Network
import os

/// Advertises the AirBridge HTTP server on the local network via mDNS
/// as `_air-bridge._tcp`. Clients can discover the service using Bonjour
/// (e.g., `dns-sd -B _air-bridge._tcp local.`).
actor ServiceAdvertiser {
    private var listener: NWListener?

    /// Begin advertising on the given port.
    func start(port: UInt16) {
        stop()

        let params = NWParameters()
        params.includePeerToPeer = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            Log.server.error("ServiceAdvertiser: invalid port \(port)")
            return
        }

        do {
            let listener = try NWListener(using: params, on: nwPort)
            listener.service = NWListener.Service(name: "AirBridge", type: "_air-bridge._tcp")
            listener.serviceRegistrationUpdateHandler = { change in
                switch change {
                case .add(let endpoint):
                    Log.server.info("mDNS service registered: \(String(describing: endpoint), privacy: .public)")
                case .remove(let endpoint):
                    Log.server.info("mDNS service removed: \(String(describing: endpoint), privacy: .public)")
                @unknown default:
                    break
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Log.server.info("ServiceAdvertiser ready on port \(port)")
                case .failed(let error):
                    Log.server.error("ServiceAdvertiser failed: \(error)")
                case .cancelled:
                    Log.server.info("ServiceAdvertiser cancelled")
                default:
                    break
                }
            }
            // Reject incoming connections — Hummingbird handles HTTP traffic.
            listener.newConnectionHandler = { conn in conn.cancel() }
            listener.start(queue: .global())
            self.listener = listener
        } catch {
            Log.server.error("ServiceAdvertiser failed to create listener: \(error)")
        }
    }

    /// Stop advertising.
    func stop() {
        listener?.cancel()
        listener = nil
    }
}
