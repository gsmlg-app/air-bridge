import Foundation
import Network
import os

/// Browses Bonjour for AirPlay receivers on the local network.
///
/// Subscribes to both `_airplay._tcp.local.` (AirPlay 2) and `_raop._tcp.local.`
/// (legacy RAOP). HomePods advertise on both — the `_airplay` service carries the
/// newer TXT records including the `features` bitmask we care about.
actor BonjourDiscovery {
    private let log = Logger(subsystem: "com.gsmlg.airbridge", category: "discovery")

    private var browsers: [NWBrowser] = []
    private var devicesByID: [String: AirPlayDevice] = [:]
    private var endpointsByID: [String: NWEndpoint] = [:]

    /// Async stream of the current device set; emits a snapshot whenever the set
    /// changes. Callers hold the returned `AsyncStream` and iterate.
    private var streamContinuations: [UUID: AsyncStream<[AirPlayDevice]>.Continuation] = [:]

    func start() {
        guard browsers.isEmpty else { return }
        log.info("Starting Bonjour browse for _airplay._tcp and _raop._tcp")
        for service in ["_airplay._tcp", "_raop._tcp"] {
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: service, domain: "local.")
            let browser = NWBrowser(for: descriptor, using: .tcp)
            browser.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleBrowserState(state, service: service) }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { await self?.handleResults(results, service: service) }
            }
            browser.start(queue: .global(qos: .userInitiated))
            browsers.append(browser)
        }
    }

    func stop() {
        for browser in browsers { browser.cancel() }
        browsers.removeAll()
        for (_, cont) in streamContinuations { cont.finish() }
        streamContinuations.removeAll()
    }

    /// Snapshot of currently-discovered devices, sorted by display name and
    /// deduplicated so each physical HomePod / Apple TV / Mac appears once.
    /// When both `_airplay._tcp` and `_raop._tcp` advertise the same physical
    /// device, we prefer the `_airplay` entry (newer, friendlier display name,
    /// real model identifier like `AudioAccessory5,1`).
    var devices: [AirPlayDevice] {
        var chosen: [String: AirPlayDevice] = [:]  // key = canonical display name
        for device in devicesByID.values {
            let key = Self.canonicalName(for: device.displayName).lowercased()
            if let existing = chosen[key] {
                // Keep whichever is the _airplay._tcp variant.
                if device.serviceType.contains("_airplay") && !existing.serviceType.contains("_airplay") {
                    chosen[key] = device
                }
            } else {
                chosen[key] = device
            }
        }
        return chosen.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// `3EB196898E74@Bedroom` → `Bedroom`. The RAOP service prefixes a MAC.
    private static func canonicalName(for name: String) -> String {
        if let atIdx = name.firstIndex(of: "@") {
            return String(name[name.index(after: atIdx)...])
        }
        return name
    }

    /// Subscribe to live updates. The returned stream terminates when `stop()` is
    /// called or when the caller cancels its consumer.
    func updates() -> AsyncStream<[AirPlayDevice]> {
        AsyncStream { continuation in
            let id = UUID()
            self.streamContinuations[id] = continuation
            continuation.yield(self.devices)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    // MARK: - Private

    private func removeContinuation(_ id: UUID) {
        streamContinuations.removeValue(forKey: id)
    }

    private func handleBrowserState(_ state: NWBrowser.State, service: String) {
        switch state {
        case .ready:
            log.info("Browser ready: \(service, privacy: .public)")
        case .failed(let err):
            log.error("Browser failed (\(service, privacy: .public)): \(err.localizedDescription, privacy: .public)")
        case .cancelled:
            log.info("Browser cancelled: \(service, privacy: .public)")
        default:
            break
        }
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, service: String) {
        // Rebuild the per-service slice from the full results set.
        // Keep entries from OTHER services intact.
        let prefix = "[\(service)]"
        devicesByID = devicesByID.filter { !$0.key.hasPrefix(prefix) }
        endpointsByID = endpointsByID.filter { !$0.key.hasPrefix(prefix) }

        for result in results {
            guard case let .service(name, type, _, _) = result.endpoint else { continue }
            let txt = extractTXT(result.metadata)
            let id = "\(prefix)\(name)"
            let device = AirPlayDevice(
                id: id,
                displayName: name,
                serviceType: type,
                txt: txt
            )
            devicesByID[id] = device
            endpointsByID[id] = result.endpoint
        }

        let snapshot = devices
        log.info("Discovery update [\(service, privacy: .public)]: \(snapshot.count) devices")
        for (_, cont) in streamContinuations { cont.yield(snapshot) }
    }

    /// Look up the `NWEndpoint` for a device by its canonical (display) name.
    /// We match by canonical name so a caller holding the deduped `_airplay` id
    /// can still get an endpoint if only the `_raop` variant is registered, etc.
    func endpoint(for deviceID: String) -> NWEndpoint? {
        if let direct = endpointsByID[deviceID] {
            return direct
        }
        // Fall back: match by canonical display name.
        guard let target = devicesByID[deviceID] ?? devicesByID.values.first(where: { $0.id == deviceID }) else {
            return nil
        }
        let targetCanonical = Self.canonicalName(for: target.displayName).lowercased()
        for (id, device) in devicesByID {
            let c = Self.canonicalName(for: device.displayName).lowercased()
            if c == targetCanonical, let endpoint = endpointsByID[id] {
                return endpoint
            }
        }
        return nil
    }

    private func extractTXT(_ metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case .bonjour(let txtRecord) = metadata else { return [:] }
        var out: [String: String] = [:]
        for (key, entry) in txtRecord {
            switch entry {
            case .string(let str):
                out[key] = str
            case .data(let data):
                if let str = String(data: data, encoding: .utf8) {
                    out[key] = str
                } else {
                    out[key] = data.map { String(format: "%02x", $0) }.joined()
                }
            case .none:
                out[key] = ""
            case .empty:
                out[key] = ""
            @unknown default:
                continue
            }
        }
        return out
    }
}
