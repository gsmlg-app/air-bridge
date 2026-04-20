import Crypto
import Foundation
import Network
import SRP
import os

/// Session keys derived after a successful HAP transient pair-setup.
/// The RTSP / audio channels use ChaCha20-Poly1305 with these keys.
struct HAPSessionKeys: Sendable {
    /// Client → Accessory encryption key (32 bytes).
    let writeKey: SymmetricKey
    /// Accessory → Client encryption key (32 bytes).
    let readKey: SymmetricKey
    /// Raw SRP shared secret K — useful for further key derivation (Audio-*, Event-*).
    let srpSharedSecret: Data
}

/// Runs the HAP transient pair-setup flow against an AirPlay 2 accessory (HomePod,
/// Apple TV) and returns the derived ChaCha20-Poly1305 session keys.
///
/// Transient pairing uses fixed credentials (`Pair-Setup` / `3939`) and skips the
/// M5/M6 persistent-identity exchange — we only need the ephemeral session keys to
/// talk to the accessory for the duration of a single audio playback.
///
/// Message flow:
///   M1 (client→accessory) state=1, method=0
///   M2 (accessory→client) state=2, salt, serverPublicKey(B)
///   M3 (client→accessory) state=3, clientPublicKey(A), proof(M1)
///   M4 (accessory→client) state=4, proof(M2)   ← transient stops here
///
/// HTTP framing: each exchange is a POST `/pair-setup` with
/// `Content-Type: application/pairing+tlv8`. Response is the same content type.
actor HAPPairing {
    private let log = Logger(subsystem: "com.gsmlg.airbridge", category: "hap")

    enum PairingError: Error {
        case connectionFailed(String)
        case httpError(Int, String)
        case malformedResponse(String)
        case accessoryError(HAPTLV8.HAPError)
        case srpFailed(String)
        case unexpectedState(UInt8)
    }

    private let endpoint: NWEndpoint
    private var connection: NWConnection?

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    // MARK: - Public entry point

    /// Run the full transient pair-setup flow. Returns derived session keys on success.
    func run() async throws -> HAPSessionKeys {
        try await openConnection()
        defer { connection?.cancel() }

        // Apple's transient flow requires a no-body preamble to /pair-pin-start.
        // This matches pyatv's behaviour (which is known to work against HomePods).
        _ = try await httpRequest(method: "POST", path: "/pair-pin-start", body: Data())

        // --- M1 ---
        // Transient pair-setup: method=0x00, state=0x01, flags=0x10 (single byte,
        // TransientPairing). pyatv sends flags as ONE byte — not a 4-byte LE uint.
        let m1 = HAPTLV8.encode([
            (HAPTLV8.TLVType.method.rawValue, Data([HAPTLV8.PairSetupMethod.pairSetup.rawValue])),
            (HAPTLV8.TLVType.state.rawValue, Data([0x01])),
            (HAPTLV8.TLVType.flags.rawValue, Data([0x10])),
        ])
        log.info("→ M1: \(m1.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
        let m2Raw = try await httpRequest(method: "POST", path: "/pair-setup", body: m1)
        log.info("← M2: \(m2Raw.map { String(format: "%02x", $0) }.joined().prefix(80), privacy: .public)… (\(m2Raw.count)B)")
        let m2 = HAPTLV8.decode(m2Raw)
        try checkError(m2)
        try expectState(m2, expected: 0x02)

        guard let salt = m2[HAPTLV8.TLVType.salt.rawValue],
              let serverPub = m2[HAPTLV8.TLVType.publicKey.rawValue] else {
            throw PairingError.malformedResponse("M2 missing salt or publicKey")
        }
        log.info("M2 received: salt=\(salt.count)B, B=\(serverPub.count)B")

        // --- M3: compute SRP client proof ---
        let client = SRPClient<SHA512>(configuration: SRPConfiguration<SHA512>(.N3072))
        let keyPair = client.generateKeys()
        let saltBytes = [UInt8](salt)
        let serverKey = SRPKey([UInt8](serverPub))
        let sharedSecret: SRPKey
        do {
            sharedSecret = try client.calculateSharedSecret(
                username: "Pair-Setup",
                password: "3939",
                salt: saltBytes,
                clientKeys: keyPair,
                serverPublicKey: serverKey
            )
        } catch {
            throw PairingError.srpFailed("shared-secret: \(error)")
        }
        let clientProof = client.calculateClientProof(
            username: "Pair-Setup",
            salt: saltBytes,
            clientPublicKey: keyPair.public,
            serverPublicKey: serverKey,
            sharedSecret: sharedSecret
        )

        let m3 = HAPTLV8.encode([
            (HAPTLV8.TLVType.state.rawValue, Data([0x03])),
            (HAPTLV8.TLVType.publicKey.rawValue, Data(keyPair.public.bytes)),
            (HAPTLV8.TLVType.proof.rawValue, Data(clientProof)),
        ])
        let m4Raw = try await httpRequest(method: "POST", path: "/pair-setup", body: m3)
        let m4 = HAPTLV8.decode(m4Raw)
        try checkError(m4)
        try expectState(m4, expected: 0x04)

        guard let serverProof = m4[HAPTLV8.TLVType.proof.rawValue] else {
            throw PairingError.malformedResponse("M4 missing server proof")
        }
        do {
            try client.verifyServerProof(
                serverProof: [UInt8](serverProof),
                clientProof: clientProof,
                clientPublicKey: keyPair.public,
                sharedSecret: sharedSecret
            )
        } catch {
            throw PairingError.srpFailed("server-proof verify: \(error)")
        }
        log.info("HAP transient pairing completed; deriving session keys")

        // swift-srp returns S (raw shared secret). HAP's HKDF input is K = H(S).
        // This matches pyatv's `_session.key` which is the hashed session key.
        let S = Data(sharedSecret.bytes)
        let K = Data(SHA512.hash(data: S))

        let writeKey = Self.hkdf(
            ikm: K,
            salt: "Control-Salt",
            info: "Control-Write-Encryption-Key",
            outputLength: 32
        )
        let readKey = Self.hkdf(
            ikm: K,
            salt: "Control-Salt",
            info: "Control-Read-Encryption-Key",
            outputLength: 32
        )
        return HAPSessionKeys(
            writeKey: SymmetricKey(data: writeKey),
            readKey: SymmetricKey(data: readKey),
            srpSharedSecret: K
        )
    }

    // MARK: - Transport

    private func openConnection() async throws {
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.connection = conn

        let resumedBox = AtomicFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumedBox.setIfUnset() { cont.resume() }
                case .failed(let err):
                    if resumedBox.setIfUnset() {
                        cont.resume(throwing: PairingError.connectionFailed(err.localizedDescription))
                    }
                case .cancelled:
                    if resumedBox.setIfUnset() {
                        cont.resume(throwing: PairingError.connectionFailed("cancelled"))
                    }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        log.info("TCP connected to \(String(describing: self.endpoint), privacy: .public)")
    }

    /// Issue an HTTP/1.1 request on the open connection using the exact header
    /// set pyatv sends (known-good against HomePods).
    private func httpRequest(method: String, path: String, body: Data) async throws -> Data {
        guard let conn = connection else { throw PairingError.connectionFailed("not connected") }

        var req = Data()
        req.append("\(method) \(path) HTTP/1.1\r\n".data(using: .utf8)!)
        req.append("User-Agent: AirPlay/320.20\r\n".data(using: .utf8)!)
        req.append("Connection: keep-alive\r\n".data(using: .utf8)!)
        req.append("X-Apple-HKP: 4\r\n".data(using: .utf8)!)
        req.append("Content-Type: application/octet-stream\r\n".data(using: .utf8)!)
        req.append("Content-Length: \(body.count)\r\n".data(using: .utf8)!)
        req.append("\r\n".data(using: .utf8)!)
        req.append(body)

        try await send(conn: conn, data: req)
        return try await receiveHTTPResponse(conn: conn)
    }

    private func send(conn: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err = err {
                    cont.resume(throwing: PairingError.connectionFailed(err.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Read an HTTP/1.1 response from the connection, returning just the body.
    /// Keeps reading until it has headers + Content-Length bytes, or the peer
    /// closes the stream. RTSP and HAP both frame this way.
    private func receiveHTTPResponse(conn: NWConnection) async throws -> Data {
        var buffer = Data()
        var headerEnd: Int?
        var contentLength = 0
        var statusCode = 0
        var statusLine = ""
        var responseHeaders: [String] = []

        while true {
            let chunk = try await receive(conn: conn)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            if headerEnd == nil {
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    headerEnd = range.upperBound
                    let headerBlock = buffer.subdata(in: 0..<range.lowerBound)
                    guard let headerString = String(data: headerBlock, encoding: .utf8) else {
                        throw PairingError.malformedResponse("non-UTF-8 headers")
                    }
                    let lines = headerString.split(separator: "\r\n").map(String.init)
                    statusLine = lines.first ?? ""
                    let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
                    if parts.count >= 2, let code = Int(parts[1]) {
                        statusCode = code
                    }
                    responseHeaders = Array(lines.dropFirst())
                    for line in responseHeaders {
                        if line.lowercased().hasPrefix("content-length:") {
                            let valuePart = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                            contentLength = Int(valuePart) ?? 0
                        }
                    }
                }
            }
            if let hEnd = headerEnd, buffer.count >= hEnd + contentLength {
                let body = buffer.subdata(in: hEnd..<(hEnd + contentLength))
                guard (200...299).contains(statusCode) else {
                    log.error("HTTP \(statusCode, privacy: .public) '\(statusLine, privacy: .public)' — headers: \(responseHeaders.joined(separator: " | "), privacy: .public), body=\(body.count)B")
                    throw PairingError.httpError(statusCode, String(data: body, encoding: .utf8) ?? "<binary>")
                }
                return body
            }
        }
        throw PairingError.malformedResponse("connection closed before full response")
    }

    private func receive(conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: PairingError.connectionFailed(error.localizedDescription))
                } else if let data = data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    // MARK: - TLV helpers

    private func checkError(_ tlv: [UInt8: Data]) throws {
        if let err = tlv[HAPTLV8.TLVType.error.rawValue], let byte = err.first {
            if let mapped = HAPTLV8.HAPError(rawValue: byte) {
                throw PairingError.accessoryError(mapped)
            }
            throw PairingError.malformedResponse("unknown error code \(byte)")
        }
    }

    private func expectState(_ tlv: [UInt8: Data], expected: UInt8) throws {
        guard let state = tlv[HAPTLV8.TLVType.state.rawValue]?.first else {
            throw PairingError.malformedResponse("missing state")
        }
        if state != expected {
            throw PairingError.unexpectedState(state)
        }
    }

    // MARK: - HKDF wrapper

    /// RFC 5869 HKDF-SHA-512 as used by HAP. CryptoKit exposes this directly
    /// via `HKDF<SHA512>.deriveKey(...)`.
    private static func hkdf(ikm: Data, salt: String, info: String, outputLength: Int) -> Data {
        let derived = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(salt.utf8),
            info: Data(info.utf8),
            outputByteCount: outputLength
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}

/// Tiny Sendable flag for single-shot continuations under Network.framework callbacks.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func setIfUnset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
