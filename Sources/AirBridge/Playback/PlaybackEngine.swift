import Foundation
import os

/// Playback is implemented on top of an `AirPlaySession` which — once Phases 2–5
/// are complete — will stream audio directly to a HomePod over AirPlay 2. Phase 1
/// holds the session skeleton; actual playback calls throw "not implemented" until
/// the protocol stack lands.
actor PlaybackEngine {
    private(set) var state: PlaybackState = .idle

    private var sessions: [String: AirPlaySession] = [:]
    private var order: [String] = []
    private var deviceSnapshots: [String: AirPlayDevice] = [:]
    private var statuses: [String: DeviceStatus] = [:]
    private weak var discovery: BonjourDiscovery?

    private var statusCallback: (@Sendable ([SelectedDevice]) -> Void)?
    private var stateCallback: (@Sendable (PlaybackState) -> Void)?
    private var trackFinishedCallback: (@Sendable () async -> Void)?

    var sessionFactory: @Sendable () -> AirPlaySession = { AirPlaySession() }

    init() {
        // no longer initializes a single session
    }

    func setStatusCallback(_ callback: @escaping @Sendable ([SelectedDevice]) -> Void) {
        self.statusCallback = callback
    }

    func selectedDevices() -> [SelectedDevice] {
        return order.compactMap { id in
            guard let snap = deviceSnapshots[id], let stat = statuses[id] else { return nil }
            return SelectedDevice(id: id, displayName: snap.displayName, status: stat)
        }
    }

    func setStateCallback(_ callback: @escaping @Sendable (PlaybackState) -> Void) {
        self.stateCallback = callback
    }

    func setTrackFinishedCallback(_ callback: @escaping @Sendable () async -> Void) {
        self.trackFinishedCallback = callback
    }

    func attachDiscovery(_ d: BonjourDiscovery) {
        self.discovery = d
    }

    // MARK: - Device selection

    /// Point the engine at a discovered AirPlay device. Pass nil to clear.
    func setDevice(_ device: AirPlayDevice?) async {
        if let d = device {
            await setSelectedDevices([d])
        } else {
            await setSelectedDevices([])
        }
    }

    var currentDevice: AirPlayDevice? {
        get async {
            guard let firstID = order.first else { return nil }
            return deviceSnapshots[firstID]
        }
    }

    func setSelectedDevices(_ requested: [AirPlayDevice]) async {
        let requestedIDs = requested.map { $0.id }
        let currentIDs = Set(order)
        let reqSet = Set(requestedIDs)

        // 1. Calculate diff
        let toRemove = currentIDs.subtracting(reqSet)
        let toAdd = reqSet.subtracting(currentIDs)

        // 2. Extract sessions to stop BEFORE modifying dictionaries
        var sessionsToStop = toRemove.compactMap { sessions[$0] }

        // 3. Synchronously mutate all actor state (No `await` here!)
        for id in toRemove {
            sessions.removeValue(forKey: id)
            statuses.removeValue(forKey: id)
            deviceSnapshots.removeValue(forKey: id)
        }

        order = requestedIDs

        for d in requested {
            if toAdd.contains(d.id) {
                let session = sessionFactory()
                sessions[d.id] = session
                deviceSnapshots[d.id] = d
                statuses[d.id] = .pairing

                if let reason = d.unsupportedTargetReason {
                    statuses[d.id] = .error(reason: reason)
                    continue
                }

                if !d.supportsAirPlay2 {
                    statuses[d.id] = .error(reason: "AirPlay 2 required")
                    continue
                }

                let currentDiscovery = self.discovery

                // Push ALL async actor messages into the connection Task
                Task { [weak self, id = d.id, session] in
                    if let currentDiscovery { await session.attachDiscovery(currentDiscovery) }
                    await session.setDevice(d)

                    do {
                        try await session.connect()
                        await self?.updateStatus(id: id, status: .ok, session: session)
                    } catch {
                        await self?.updateStatus(id: id, status: .error(reason: error.localizedDescription), session: session)
                    }
                }
            } else if deviceSnapshots[d.id] != nil {
                // Update displayNames for existing devices in case of rename
                deviceSnapshots[d.id] = d
                if let reason = d.unsupportedTargetReason {
                    statuses[d.id] = .error(reason: reason)
                    if let session = sessions.removeValue(forKey: d.id) {
                        sessionsToStop.append(session)
                    }
                } else if !d.supportsAirPlay2 {
                    statuses[d.id] = .error(reason: "AirPlay 2 required")
                    if let session = sessions.removeValue(forKey: d.id) {
                        sessionsToStop.append(session)
                    }
                }
            }
        }

        // Fire callback to reflect new state immediately
        fireStatusCallback()

        // 4. Asynchronously stop old sessions now that internal state is completely settled
        for session in sessionsToStop {
            await session.stop()
        }
    }

    private func updateStatus(id: String, status: DeviceStatus, session expectedSession: AirPlaySession? = nil) {
        if let expectedSession, sessions[id] !== expectedSession {
            return
        }
        if statuses[id] != nil {
            statuses[id] = status
            fireStatusCallback()
        }
    }

    private func fireStatusCallback() {
        let snap = selectedDevices()
        statusCallback?(snap)
    }

    func markOffline(deviceID: String) {
        if statuses[deviceID] != nil {
            statuses[deviceID] = .offline
            fireStatusCallback()
        }
    }

    func retry(deviceID: String) {
        guard let session = sessions[deviceID], let _ = deviceSnapshots[deviceID] else { return }
        statuses[deviceID] = .pairing
        fireStatusCallback()

        Task { [weak self] in
            do {
                try await session.connect()
                await self?.updateStatus(id: deviceID, status: .ok, session: session)
            } catch {
                await self?.updateStatus(id: deviceID, status: .error(reason: error.localizedDescription), session: session)
            }
        }
    }

    /// Legacy hook kept for API compatibility with earlier UID-based callers;
    /// a no-op in the AirPlay architecture because routing is by Bonjour device,
    /// not CoreAudio UID.
    func setOutputDevice(uid: String) async throws -> Bool { false }
    var outputDeviceUID: String? { nil }

    // MARK: - Playback

    func play(track: QueueTrack) async throws {
        let url = URL(fileURLWithPath: track.stagedPath)
        var errors: [String: Error] = [:]
        let attemptedIDs = order

        await withTaskGroup(of: (String, Error?).self) { group in
            for id in attemptedIDs {
                guard let session = sessions[id] else { continue }
                group.addTask {
                    do { try await session.play(fileURL: url); return (id, nil) }
                    catch { return (id, error) }
                }
            }
            for await (id, err) in group { if let err = err { errors[id] = err } }
        }

        // Prevent state overwrite if stop() was called during suspension
        guard !Task.isCancelled else { return }
        guard case .idle = state else { return }

        if let first = errors.first, errors.count == attemptedIDs.count, !attemptedIDs.isEmpty {
            let msg = "All devices failed; first=\(first.key): \(first.value.localizedDescription)"
            transition(to: .error(message: msg))
            throw first.value
        } else {
            transition(to: .playing(file: track.originalFilename))
            Log.playback.info("Playing \(track.originalFilename, privacy: .public)")
        }
    }

    func stop() async -> PlaybackState {
        let sessionsToStop = order.compactMap { sessions[$0] }
        await withTaskGroup(of: Void.self) { group in
            for session in sessionsToStop {
                group.addTask {
                    await session.stop()
                }
            }
        }
        transition(to: .idle)
        return state
    }

    func pause() -> PlaybackState {
        if case .playing(let file) = state {
            transition(to: .paused(file: file))
        }
        return state
    }

    func resume() -> PlaybackState {
        if case .paused(let file) = state {
            transition(to: .playing(file: file))
        }
        return state
    }

    // MARK: - Private

    private func transition(to newState: PlaybackState) {
        let oldState = state
        state = newState
        if oldState != newState, let cb = stateCallback {
            let s = newState
            Task { @MainActor in cb(s) }
        }
    }
}

enum PlaybackEngineError: Error, Sendable {
    case deviceNotFound(uid: String)
    case deviceUnavailable(uid: String)
    case engineSetupFailed
    case noAirPlayRoute
}
