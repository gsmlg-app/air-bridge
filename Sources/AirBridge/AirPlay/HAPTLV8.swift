import Foundation

/// TLV8 (Type-Length-Value, 8-bit type) codec as used by HomeKit Accessory Protocol
/// pair-setup / pair-verify messages.
///
/// Format: [type: UInt8][length: UInt8][value: length bytes]. Values longer than 255
/// bytes are split into consecutive fragments with the same type, each at most 255
/// bytes; decoders concatenate them. Multiple distinct types may appear in any order.
enum HAPTLV8 {
    /// Standard HAP TLV types used during pair-setup.
    enum TLVType: UInt8 {
        case method = 0x00
        case identifier = 0x01
        case salt = 0x02
        case publicKey = 0x03
        case proof = 0x04
        case encryptedData = 0x05
        case state = 0x06
        case error = 0x07
        case retryDelay = 0x08
        case certificate = 0x09
        case signature = 0x0a
        case permissions = 0x0b
        case fragmentData = 0x0c
        case fragmentLast = 0x0d
        case flags = 0x13
        case separator = 0xff
    }

    /// HAP pair-setup method values.
    enum PairSetupMethod: UInt8 {
        case pairSetup = 0x00
        case pairSetupWithAuth = 0x01
        case pairVerify = 0x02
        case addPairing = 0x03
        case removePairing = 0x04
        case listPairings = 0x05
    }

    /// Error codes returned in TLVType.error.
    enum HAPError: UInt8, Error {
        case unknown = 0x01
        case authentication = 0x02
        case backoff = 0x03
        case maxPeers = 0x04
        case maxTries = 0x05
        case unavailable = 0x06
        case busy = 0x07
    }

    /// Encode a sequence of (type, value) pairs into TLV8 bytes. Values longer
    /// than 255 bytes are fragmented automatically.
    static func encode(_ items: [(UInt8, Data)]) -> Data {
        var out = Data()
        for (type, value) in items {
            if value.isEmpty {
                out.append(type)
                out.append(0)
                continue
            }
            var remaining = value
            while !remaining.isEmpty {
                let chunkLen = min(remaining.count, 255)
                out.append(type)
                out.append(UInt8(chunkLen))
                out.append(remaining.prefix(chunkLen))
                remaining.removeFirst(chunkLen)
            }
        }
        return out
    }

    static func encode(_ type: UInt8, _ value: Data) -> Data {
        encode([(type, value)])
    }

    static func encode(_ type: UInt8, byte: UInt8) -> Data {
        encode([(type, Data([byte]))])
    }

    /// Parse TLV8 bytes into a dictionary keyed by type. Consecutive records of
    /// the same type are concatenated (this is how HAP represents values > 255B).
    static func decode(_ data: Data) -> [UInt8: Data] {
        var out: [UInt8: Data] = [:]
        var i = 0
        while i + 2 <= data.count {
            let type = data[data.startIndex + i]
            let len = Int(data[data.startIndex + i + 1])
            let valueStart = i + 2
            let valueEnd = valueStart + len
            guard valueEnd <= data.count else { break }
            let chunk = data.subdata(in: (data.startIndex + valueStart)..<(data.startIndex + valueEnd))
            if var existing = out[type] {
                existing.append(chunk)
                out[type] = existing
            } else {
                out[type] = chunk
            }
            i = valueEnd
        }
        return out
    }
}
