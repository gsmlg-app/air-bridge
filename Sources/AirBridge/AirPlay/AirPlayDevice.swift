import Foundation
import Network

/// A HomePod, Apple TV, or other AirPlay receiver discovered on the LAN.
struct AirPlayDevice: Identifiable, Sendable, Hashable, Codable {
    /// Bonjour instance name — stable across network reconnects for the same device.
    let id: String
    /// User-visible name (typically the same as the Bonjour name minus the service type).
    let displayName: String
    /// Bonjour service type that surfaced this device (`_airplay._tcp.` vs `_raop._tcp.`).
    let serviceType: String
    /// Raw TXT record key/value pairs (ASCII only). Useful for debugging.
    let txt: [String: String]

    /// `features` bitmask parsed from the `features` / `ft` TXT field. 0 if absent.
    var featuresBitmask: UInt64 {
        if let value = txt["features"] ?? txt["ft"] {
            return Self.parseFeatures(value)
        }
        return 0
    }

    /// AirPlay 2 is signalled by TXT features bit 48 (transient pairing) being set.
    var supportsAirPlay2: Bool {
        (featuresBitmask & (1 << 48)) != 0 || serviceType.contains("_airplay._tcp")
    }

    /// Every modern HomePod requires HAP pairing; RAOP-only legacy speakers do not.
    var requiresPairing: Bool {
        supportsAirPlay2
    }

    /// Model identifier from TXT `md` or `model`.
    var modelID: String? {
        txt["md"] ?? txt["model"]
    }

    /// Parse a `features` string — may be a hex value like `"0x4A7FDFD5,0xBC157FDE"`
    /// (two 32-bit halves) or a plain decimal.
    static func parseFeatures(_ raw: String) -> UInt64 {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(",") {
            let parts = trimmed.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2,
               let low = UInt32(parts[0].replacingOccurrences(of: "0x", with: ""), radix: 16),
               let high = UInt32(parts[1].replacingOccurrences(of: "0x", with: ""), radix: 16) {
                return (UInt64(high) << 32) | UInt64(low)
            }
        }
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            return UInt64(trimmed.dropFirst(2), radix: 16) ?? 0
        }
        return UInt64(trimmed) ?? 0
    }
}
