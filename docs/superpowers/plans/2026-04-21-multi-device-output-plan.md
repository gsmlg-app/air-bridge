# Multi-Device AirPlay Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform the single-device output pipeline into a multi-device pipeline supporting 1..8 devices with parallel session state.
**Architecture:** Data model (`SelectedDevice`), internal bookkeeping in `PlaybackEngine` (dictionary of `AirPlaySession`s), updated `AppState` bridging HTTP/UI, and expanded `APIRoutes`.
**Tech Stack:** Swift, actors, Hummingbird (for API), SwiftUI.

---

### Task 1: SelectedDevice Data Model

**Files:**
- Create: `Sources/AirBridge/AirPlay/SelectedDevice.swift`
- Create: `Tests/AirBridgeTests/SelectedDeviceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AirBridgeTests/SelectedDeviceTests.swift
import XCTest
@testable import AirBridge

final class SelectedDeviceTests: XCTestCase {
    func testCodableRoundtrip() throws {
        let original = SelectedDevice(id: "homepod.local", displayName: "HomePod", status: .error(reason: "timeout"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SelectedDevice.self, from: data)
        XCTAssertEqual(original, decoded)
        if case .error(let reason) = decoded.status {
            XCTAssertEqual(reason, "timeout")
        } else {
            XCTFail("Wrong status")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SelectedDevice`
Expected: FAIL due to missing types.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/AirBridge/AirPlay/SelectedDevice.swift
import Foundation

enum DeviceStatus: Sendable, Hashable, Codable, Equatable {
    case pairing
    case ok
    case offline
    case error(reason: String)
}

struct SelectedDevice: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let displayName: String
    var status: DeviceStatus
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SelectedDevice`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AirBridge/AirPlay/SelectedDevice.swift Tests/AirBridgeTests/SelectedDeviceTests.swift
git commit -m "feat: add SelectedDevice and DeviceStatus models"
```

---

### Task 2: PlaybackEngine - State & Read API

**Files:**
- Modify: `Sources/AirBridge/Playback/PlaybackEngine.swift`
- Create: `Tests/AirBridgeTests/PlaybackEngineTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AirBridgeTests/PlaybackEngineTests.swift
import XCTest
@testable import AirBridge

final class PlaybackEngineTests: XCTestCase {
    func testInitialState() async {
        let engine = PlaybackEngine()
        let selected = await engine.selectedDevices()
        XCTAssertTrue(selected.isEmpty)
        let current = await engine.currentDevice
        XCTAssertNil(current)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PlaybackEngineTests.testInitialState`
Expected: FAIL (missing methods).

- [ ] **Step 3: Write minimal implementation**

```swift
// In Sources/AirBridge/Playback/PlaybackEngine.swift
// Add to PlaybackEngine actor:
    private var sessions: [String: AirPlaySession] = [:]
    private var order: [String] = []
    private var deviceSnapshots: [String: AirPlayDevice] = [:]
    private var statuses: [String: DeviceStatus] = [:]
    private weak var discovery: BonjourDiscovery?
    
    private var statusCallback: (@Sendable ([SelectedDevice]) -> Void)?
    var sessionFactory: @Sendable () -> AirPlaySession = { AirPlaySession() }

    func setStatusCallback(_ callback: @escaping @Sendable ([SelectedDevice]) -> Void) {
        self.statusCallback = callback
    }

    func selectedDevices() -> [SelectedDevice] {
        return order.compactMap { id in
            guard let snap = deviceSnapshots[id], let stat = statuses[id] else { return nil }
            return SelectedDevice(id: id, displayName: snap.displayName, status: stat)
        }
    }

// Update existing properties:
    // REMOVE `let session: AirPlaySession` and replace with `sessions` mapping.
    // Update init:
    init() {
        // no longer initializes a single session
    }

    // Update setDevice to delegate:
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

    // Placeholder for next task
    func setSelectedDevices(_ devices: [AirPlayDevice]) async {
        // implemented in next task
    }
```

*Note: You will need to temporarily comment out `play`, `stop`, `pause`, `resume` implementations that rely on the old `self.session` property, to allow compilation, or update them to do nothing for now.*

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PlaybackEngineTests.testInitialState`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AirBridge/Playback/PlaybackEngine.swift Tests/AirBridgeTests/PlaybackEngineTests.swift
git commit -m "refactor: convert PlaybackEngine to multi-session state"
```

---

### Task 3: PlaybackEngine - Selection Diff & Pairing

**Files:**
- Modify: `Sources/AirBridge/Playback/PlaybackEngine.swift`
- Modify: `Tests/AirBridgeTests/PlaybackEngineTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// In Tests/AirBridgeTests/PlaybackEngineTests.swift
    func testSetSelectedDevices() async {
        let engine = PlaybackEngine()
        let d1 = AirPlayDevice(id: "1", displayName: "One", serviceType: "_airplay._tcp.", txt: [:])
        
        await engine.setSelectedDevices([d1])
        let selected = await engine.selectedDevices()
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected[0].id, "1")
        // Since discovery is nil, connect() will fail immediately with .error
        // Wait a tick for the detached task to finish
        try? await Task.sleep(nanoseconds: 50_000_000)
        let updated = await engine.selectedDevices()
        if case .error = updated[0].status {
            // expected
        } else {
            XCTFail("Should have errored due to no discovery")
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PlaybackEngineTests.testSetSelectedDevices`
Expected: FAIL (setSelectedDevices is empty).

- [ ] **Step 3: Write minimal implementation**

```swift
// In Sources/AirBridge/Playback/PlaybackEngine.swift
// Update `setSelectedDevices`

    func setSelectedDevices(_ requested: [AirPlayDevice]) async {
        let requestedIDs = requested.map { $0.id }
        let currentIDs = Set(order)
        let reqSet = Set(requestedIDs)
        
        let toRemove = currentIDs.subtracting(reqSet)
        for id in toRemove {
            await sessions[id]?.stop()
            sessions.removeValue(forKey: id)
            statuses.removeValue(forKey: id)
            deviceSnapshots.removeValue(forKey: id)
        }
        
        let toAdd = reqSet.subtracting(currentIDs)
        for d in requested where toAdd.contains(d.id) {
            let session = sessionFactory()
            if let discovery { await session.attachDiscovery(discovery) }
            await session.setDevice(d)
            
            sessions[d.id] = session
            deviceSnapshots[d.id] = d
            statuses[d.id] = .pairing
            
            if !d.supportsAirPlay2 {
                statuses[d.id] = .error(reason: "AirPlay 2 required")
                continue
            }
            
            Task { [weak self, id = d.id] in
                do {
                    try await session.connect()
                    await self?.updateStatus(id: id, status: .ok)
                } catch {
                    await self?.updateStatus(id: id, status: .error(reason: error.localizedDescription))
                }
            }
        }
        
        order = requestedIDs
        // update displayNames for existing devices in case of rename
        for d in requested {
            if deviceSnapshots[d.id] != nil {
                deviceSnapshots[d.id] = d
            }
        }
        
        fireStatusCallback()
    }

    private func updateStatus(id: String, status: DeviceStatus) {
        if statuses[id] != nil {
            statuses[id] = status
            fireStatusCallback()
        }
    }

    private func fireStatusCallback() {
        let snap = selectedDevices()
        statusCallback?(snap)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PlaybackEngineTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AirBridge/Playback/PlaybackEngine.swift Tests/AirBridgeTests/PlaybackEngineTests.swift
git commit -m "feat: PlaybackEngine setSelectedDevices diff and connect"
```

---

### Task 4: PlaybackEngine - Offline, Retry, and Play Fan-out

**Files:**
- Modify: `Sources/AirBridge/Playback/PlaybackEngine.swift`
- Modify: `Tests/AirBridgeTests/PlaybackEngineTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// In Tests/AirBridgeTests/PlaybackEngineTests.swift
    func testOfflineAndRetry() async {
        let engine = PlaybackEngine()
        let d1 = AirPlayDevice(id: "1", displayName: "One", serviceType: "_airplay._tcp.", txt: [:])
        await engine.setSelectedDevices([d1])
        await engine.markOffline(deviceID: "1")
        
        let offlineSnap = await engine.selectedDevices()
        XCTAssertEqual(offlineSnap[0].status, .offline)
        
        await engine.retry(deviceID: "1")
        let retrySnap = await engine.selectedDevices()
        XCTAssertEqual(retrySnap[0].status, .pairing)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PlaybackEngineTests.testOfflineAndRetry`
Expected: FAIL (missing methods).

- [ ] **Step 3: Write minimal implementation**

```swift
// In Sources/AirBridge/Playback/PlaybackEngine.swift
    func markOffline(deviceID: String) {
        if statuses[deviceID] != nil {
            statuses[deviceID] = .offline
            fireStatusCallback()
        }
    }

    func retry(deviceID: String) {
        guard let session = sessions[deviceID], let d = deviceSnapshots[deviceID] else { return }
        statuses[deviceID] = .pairing
        fireStatusCallback()
        
        Task { [weak self] in
            do {
                try await session.connect()
                await self?.updateStatus(id: deviceID, status: .ok)
            } catch {
                await self?.updateStatus(id: deviceID, status: .error(reason: error.localizedDescription))
            }
        }
    }
    
    // Update play() to fan-out:
    func play(track: QueueTrack) async throws {
        let url = URL(fileURLWithPath: track.stagedPath)
        var errors: [String: Error] = [:]
        
        await withTaskGroup(of: (String, Error?).self) { group in
            for id in order {
                guard let session = sessions[id] else { continue }
                group.addTask {
                    do { try await session.play(fileURL: url); return (id, nil) }
                    catch { return (id, error) }
                }
            }
            for await (id, err) in group { if let err = err { errors[id] = err } }
        }
        
        if errors.count == order.count, !order.isEmpty {
            let first = errors.first!
            let msg = "All devices failed; first=\(first.key): \(first.value.localizedDescription)"
            transition(to: .error(message: msg))
            throw first.value
        } else {
            transition(to: .playing(file: track.originalFilename))
            Log.playback.info("Playing \(track.originalFilename, privacy: .public)")
        }
    }

    // Update stop, pause, resume:
    func stop() async -> PlaybackState {
        for id in order {
            await sessions[id]?.stop()
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PlaybackEngineTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AirBridge/Playback/PlaybackEngine.swift Tests/AirBridgeTests/PlaybackEngineTests.swift
git commit -m "feat: PlaybackEngine offline, retry, and play fan-out"
```

---

### Task 5: AppState - Core State & Migration

**Files:**
- Modify: `Sources/AirBridge/App/AppState.swift`

- [ ] **Step 1: Write the code**

Update `AppState.swift` to handle `selectedDevices` and migration.

```swift
// In Sources/AirBridge/App/AppState.swift
// Replace @Published var selectedDevice with selectedDevices:
    @Published var selectedDevices: [SelectedDevice] = []

// In init(), replace the migration block with:
    Task {
        await engine.setStatusCallback { [weak self] devices in
            Task { @MainActor in
                self?.selectedDevices = devices
            }
        }
    }

    // Restore previously-saved devices
    let savedIDs: [String]
    if let data = UserDefaults.standard.data(forKey: "selectedAirPlayDeviceIDs"),
       let decoded = try? JSONDecoder().decode([String].self, from: data) {
        savedIDs = decoded
    } else if let legacyID = UserDefaults.standard.string(forKey: "selectedAirPlayDeviceID"), !legacyID.isEmpty {
        savedIDs = [legacyID]
        let data = try? JSONEncoder().encode(savedIDs)
        UserDefaults.standard.set(data, forKey: "selectedAirPlayDeviceIDs")
        UserDefaults.standard.removeObject(forKey: "selectedAirPlayDeviceID")
    } else {
        savedIDs = []
    }

    if !savedIDs.isEmpty {
        Task { [weak self] in
            guard let self else { return }
            // Seed offline devices immediately so UI shows them
            let offlineDevices = savedIDs.map { id in
                AirPlayDevice(id: id, displayName: id, serviceType: "_airplay._tcp.", txt: [:])
            }
            await self.engine.setSelectedDevices(offlineDevices)
            for id in savedIDs {
                await self.engine.markOffline(deviceID: id)
            }
            
            try? await Task.sleep(for: .seconds(2))
            let devices = await MainActor.run { self.airplayDevices }
            let toSelect = savedIDs.compactMap { id in devices.first(where: { $0.id == id }) }
            if !toSelect.isEmpty {
                await self.engine.setSelectedDevices(toSelect)
            }
        }
    }

// Update discoveryTask consumer loop:
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.discovery.updates()
            for await devices in stream {
                await MainActor.run {
                    self.airplayDevices = devices
                }
                // Handle offline/retry
                let currentSelected = await self.engine.selectedDevices()
                for sel in currentSelected {
                    let inBonjour = devices.contains(where: { $0.id == sel.id })
                    if !inBonjour && sel.status != .offline {
                        await self.engine.markOffline(deviceID: sel.id)
                    } else if inBonjour && sel.status == .offline {
                        await self.engine.retry(deviceID: sel.id)
                    }
                }
            }
        }
```
*(Remove the old `selectAirPlayDevice(_:)` for now, to be replaced next)*

- [ ] **Step 2: Commit**

```bash
git add Sources/AirBridge/App/AppState.swift
git commit -m "feat: AppState migration to selectedDevices and offline tracking"
```

---

### Task 6: AppState - UI Selection helpers

**Files:**
- Modify: `Sources/AirBridge/App/AppState.swift`

- [ ] **Step 1: Write the code**

```swift
// In Sources/AirBridge/App/AppState.swift
// Add these helper methods to replace `selectAirPlayDevice(_:)`
    
    /// Replaces the entire selection based on HTTP API requests.
    func setSelectedDevices(_ ids: [String]) async {
        let devices = await MainActor.run { self.airplayDevices }
        var resolved: [AirPlayDevice] = []
        for id in ids {
            if let d = devices.first(where: { $0.id == id }) {
                resolved.append(d)
            } else {
                // Unknown to Bonjour right now, construct a stub to track offline
                resolved.append(AirPlayDevice(id: id, displayName: id, serviceType: "_airplay._tcp.", txt: [:]))
            }
        }
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: "selectedAirPlayDeviceIDs")
        }
        await engine.setSelectedDevices(resolved)
        
        // Mark unknown ones offline immediately
        for id in ids {
            if !devices.contains(where: { $0.id == id }) {
                await engine.markOffline(deviceID: id)
            }
        }
    }

    /// Toggles a single device for the Settings UI checkboxes.
    func toggleSelection(_ device: AirPlayDevice) async {
        let currentIDs = await engine.selectedDevices().map(\.id)
        var newIDs = currentIDs
        if let idx = newIDs.firstIndex(of: device.id) {
            newIDs.remove(at: idx)
        } else {
            if newIDs.count < 8 {
                newIDs.append(device.id)
            }
        }
        await setSelectedDevices(newIDs)
    }
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AirBridge/App/AppState.swift
git commit -m "feat: AppState setSelectedDevices and toggleSelection helpers"
```

---

### Task 7: API Routes - `GET /status` and `GET /outputs`

**Files:**
- Modify: `Sources/AirBridge/Transport/APIRoutes.swift`

- [ ] **Step 1: Write the code**

Update `StatusResponse` and `OutputsResponse` models, and the GET endpoints.

```swift
// In Sources/AirBridge/Transport/APIRoutes.swift
// Add to top of file (or near other models):
struct SelectedDeviceInfo: Encodable {
    let id: String
    let name: String
    let status: String
    let status_reason: String?
    let online: Bool
}

// Update StatusResponse shape:
struct StatusResponse: Encodable {
    struct OutputInfo: Encodable {
        let airplay_device_id: String?
        let airplay_device_name: String?
    }
    struct TrackRef: Encodable { let id: String; let filename: String }
    let status: String
    let track: TrackRef?
    let queue_length: Int
    let queue_position: Int?
    let output: OutputInfo?
    let outputs: [SelectedDeviceInfo]
    let error: String?
}

// Update OutputsResponse shape:
struct AirPlayDeviceInfo: Encodable {
    let id: String
    let name: String
    let model: String?
    let supports_airplay_2: Bool
    let requires_pairing: Bool
    let is_selected: Bool
    let selected_order: Int?
}

struct OutputsResponse: Encodable {
    let selected: AirPlayDeviceInfo?
    let selected_devices: [SelectedDeviceInfo]
    let devices: [AirPlayDeviceInfo]
}

// Update GET /status:
    router.get("status") { _, _ -> Response in
        let engineState = await engine.state
        let queueState = await queue.list()
        let selectedSnapshots = await engine.selectedDevices()
        
        let track: StatusResponse.TrackRef? = queueState.currentTrack.map {
            .init(id: $0.id.uuidString, filename: $0.originalFilename)
        }
        
        let outputsInfo = selectedSnapshots.map { s -> SelectedDeviceInfo in
            let reason: String? = { if case .error(let r) = s.status { return r }; return nil }()
            let statusStr: String = {
                switch s.status {
                case .pairing: return "pairing"
                case .ok: return "ok"
                case .offline: return "offline"
                case .error: return "error"
                }
            }()
            return SelectedDeviceInfo(id: s.id, name: s.displayName, status: statusStr, status_reason: reason, online: s.status != .offline)
        }
        
        let first = selectedSnapshots.first
        
        let resp = StatusResponse(
            status: engineState.statusString,
            track: track,
            queue_length: queueState.tracks.count,
            queue_position: queueState.currentIndex,
            output: StatusResponse.OutputInfo(
                airplay_device_id: first?.id,
                airplay_device_name: first?.displayName
            ),
            outputs: outputsInfo,
            error: engineState.errorMessage
        )
        return try jsonResponse(resp)
    }

// Update GET /outputs:
    router.get("outputs") { _, _ -> Response in
        let devices = await discovery?.devices ?? []
        let selectedSnapshots = await engine.selectedDevices()
        let selectedIDs = selectedSnapshots.map(\.id)
        
        let infos = devices.map { d -> AirPlayDeviceInfo in
            let order = selectedIDs.firstIndex(of: d.id)
            return AirPlayDeviceInfo(
                id: d.id,
                name: d.displayName,
                model: d.modelID,
                supports_airplay_2: d.supportsAirPlay2,
                requires_pairing: d.requiresPairing,
                is_selected: order != nil,
                selected_order: order
            )
        }
        
        let outputsInfo = selectedSnapshots.map { s -> SelectedDeviceInfo in
            let reason: String? = { if case .error(let r) = s.status { return r }; return nil }()
            let statusStr: String = {
                switch s.status {
                case .pairing: return "pairing"
                case .ok: return "ok"
                case .offline: return "offline"
                case .error: return "error"
                }
            }()
            return SelectedDeviceInfo(id: s.id, name: s.displayName, status: statusStr, status_reason: reason, online: s.status != .offline)
        }
        
        let firstSelected = infos.first { $0.is_selected && $0.selected_order == 0 }
        
        return try jsonResponse(OutputsResponse(selected: firstSelected, selected_devices: outputsInfo, devices: infos))
    }
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AirBridge/Transport/APIRoutes.swift
git commit -m "feat: API routes GET /status and /outputs include arrays"
```

---

### Task 8: API Routes - Plural Endpoints

**Files:**
- Modify: `Sources/AirBridge/Transport/APIRoutes.swift`

- [ ] **Step 1: Write the code**

```swift
// In Sources/AirBridge/Transport/APIRoutes.swift
// Add Models:
struct SelectedOutputsResponse: Encodable {
    let max: Int
    let devices: [SelectedDeviceInfo]
}

struct PutSelectedRequest: Decodable {
    let ids: [String]
}

// Add GET /outputs/selected
    router.get("outputs/selected") { _, _ -> Response in
        let selectedSnapshots = await engine.selectedDevices()
        let outputsInfo = selectedSnapshots.map { s -> SelectedDeviceInfo in
            let reason: String? = { if case .error(let r) = s.status { return r }; return nil }()
            let statusStr: String = {
                switch s.status {
                case .pairing: return "pairing"
                case .ok: return "ok"
                case .offline: return "offline"
                case .error: return "error"
                }
            }()
            return SelectedDeviceInfo(id: s.id, name: s.displayName, status: statusStr, status_reason: reason, online: s.status != .offline)
        }
        return try jsonResponse(SelectedOutputsResponse(max: 8, devices: outputsInfo))
    }

// Add PUT /outputs/selected
    router.put("outputs/selected") { request, context -> Response in
        guard let body = try? await request.decode(as: PutSelectedRequest.self, context: context) else {
            return try jsonResponse(ErrorResponse(error: "invalid_request", message: "Missing 'ids' array"), status: .badRequest)
        }
        
        if body.ids.count > 8 {
            return try jsonResponse(ErrorResponse(error: "too_many_devices", message: "max 8 devices"), status: .badRequest)
        }
        
        var seen = Set<String>()
        for id in body.ids {
            if seen.contains(id) {
                return try jsonResponse(ErrorResponse(error: "duplicate_ids", message: "id '\(id)' appears twice"), status: .badRequest)
            }
            seen.insert(id)
            // 404 validation
            let devices = await discovery?.devices ?? []
            if !devices.contains(where: { $0.id == id }) {
                return try jsonResponse(ErrorResponse(error: "device_not_found", message: "No AirPlay device with id: \(id)"), status: .notFound)
            }
        }
        
        if let appState = appState {
            await appState.setSelectedDevices(body.ids)
        }
        
        // Build immediate response matching GET
        let selectedSnapshots = await engine.selectedDevices()
        let outputsInfo = selectedSnapshots.map { s -> SelectedDeviceInfo in
            let reason: String? = { if case .error(let r) = s.status { return r }; return nil }()
            let statusStr: String = {
                switch s.status {
                case .pairing: return "pairing"
                case .ok: return "ok"
                case .offline: return "offline"
                case .error: return "error"
                }
            }()
            return SelectedDeviceInfo(id: s.id, name: s.displayName, status: statusStr, status_reason: reason, online: s.status != .offline)
        }
        return try jsonResponse(SelectedOutputsResponse(max: 8, devices: outputsInfo))
    }
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AirBridge/Transport/APIRoutes.swift
git commit -m "feat: plural API endpoints /outputs/selected"
```

---

### Task 9: API Routes - Legacy Aliases

**Files:**
- Modify: `Sources/AirBridge/Transport/APIRoutes.swift`

- [ ] **Step 1: Write the code**

```swift
// In Sources/AirBridge/Transport/APIRoutes.swift
// Update GET /outputs/current to use new selectedDevices
    router.get("outputs/current") { _, _ -> Response in
        let selectedSnapshots = await engine.selectedDevices()
        let devices = await discovery?.devices ?? []
        guard let first = selectedSnapshots.first, let fullDevice = devices.first(where: { $0.id == first.id }) else {
            return try jsonResponse(ErrorResponse(error: "none_selected", message: "No AirPlay device selected"), status: .notFound)
        }
        
        struct OutputCurrentResponse: Encodable {
            let id: String; let name: String; let model: String?; let supports_airplay_2: Bool
        }
        
        return try jsonResponse(OutputCurrentResponse(
            id: fullDevice.id,
            name: fullDevice.displayName,
            model: fullDevice.modelID,
            supports_airplay_2: fullDevice.supportsAirPlay2
        ))
    }

// Update PUT /outputs/current to pass through appState.setSelectedDevices
    router.put("outputs/current") { request, context -> Response in
        struct SetOutputRequest: Decodable { let id: String }
        let body = try await request.decode(as: SetOutputRequest.self, context: context)
        
        let devices = await discovery?.devices ?? []
        guard let fullDevice = devices.first(where: { $0.id == body.id }) else {
            return try jsonResponse(
                ErrorResponse(error: "device_not_found", message: "No AirPlay device with id: \(body.id)"),
                status: .notFound
            )
        }
        if let appState = appState {
            await appState.setSelectedDevices([body.id])
        }
        
        struct OutputCurrentResponse: Encodable {
            let id: String; let name: String; let model: String?; let supports_airplay_2: Bool
        }
        return try jsonResponse(OutputCurrentResponse(
            id: fullDevice.id,
            name: fullDevice.displayName,
            model: fullDevice.modelID,
            supports_airplay_2: fullDevice.supportsAirPlay2
        ))
    }
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AirBridge/Transport/APIRoutes.swift
git commit -m "refactor: preserve legacy behavior for /outputs/current"
```

---

### Task 10: SwiftUI - MenuBarView

**Files:**
- Modify: `Sources/AirBridge/MenuBar/MenuBarView.swift`

- [ ] **Step 1: Write the code**

Update `MenuBarView` to display N selected devices.

```swift
// In Sources/AirBridge/MenuBar/MenuBarView.swift
// Replace the AirPlay target HStack block (around line 50) with:

            // AirPlay target
            HStack {
                Image(systemName: "airplayaudio")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if appState.selectedDevices.isEmpty {
                    Text("No AirPlay device")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else {
                    let first = appState.selectedDevices[0]
                    let suffix = appState.selectedDevices.count > 1 ? " +\(appState.selectedDevices.count - 1)" : ""
                    
                    var statusSuffix = ""
                    if appState.selectedDevices.count == 1 {
                        switch first.status {
                        case .error: statusSuffix = " (error)"
                        case .offline: statusSuffix = " (offline)"
                        default: break
                        }
                    }
                    
                    Text("\(first.displayName)\(suffix)\(statusSuffix)")
                        .font(.caption)
                        .bold()
                }
            }
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AirBridge/MenuBar/MenuBarView.swift
git commit -m "feat: MenuBarView multi-device summary"
```

---

### Task 11: SwiftUI - SettingsView

**Files:**
- Modify: `Sources/AirBridge/MenuBar/SettingsView.swift`

- [ ] **Step 1: Write the code**

Refactor `SettingsView` to use multiple checkboxes with status badges.

```swift
// In Sources/AirBridge/MenuBar/SettingsView.swift
// Remove @AppStorage("selectedAirPlayDeviceID") property.
// Replace `binding(for device: AirPlayDevice)` with:
    private func binding(for device: AirPlayDevice) -> Binding<Bool> {
        Binding(
            get: { appState.selectedDevices.contains(where: { $0.id == device.id }) },
            set: { _ in
                Task { await appState.toggleSelection(device) }
            }
        )
    }

// Replace the AirPlay Output Section with:
            Section("AirPlay Output") {
                if appState.airplayDevices.isEmpty && appState.selectedDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Scanning for AirPlay devices…", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundColor(.secondary)
                        Text("HomePods and Apple TVs on your Wi-Fi network should appear here within a few seconds.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        // Show all Bonjour devices, plus any selected offline ones
                        let allIDs = Set(appState.airplayDevices.map(\.id)).union(appState.selectedDevices.map(\.id))
                        let sortedIDs = Array(allIDs).sorted()
                        
                        ForEach(sortedIDs, id: \.self) { id in
                            let device = appState.airplayDevices.first(where: { $0.id == id }) ?? AirPlayDevice(id: id, displayName: id, serviceType: "", txt: [:])
                            let isSelected = appState.selectedDevices.contains(where: { $0.id == id })
                            let isAtLimit = appState.selectedDevices.count >= 8
                            let isDisabled = !isSelected && isAtLimit
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Toggle(isOn: binding(for: device)) {
                                        HStack {
                                            Text(device.displayName)
                                            if let model = device.modelID {
                                                Text("(\(model))").font(.caption).foregroundColor(.secondary)
                                            }
                                            if device.supportsAirPlay2 {
                                                Text("AirPlay 2").font(.caption2).padding(.horizontal, 4).background(Color.blue.opacity(0.2)).cornerRadius(3)
                                            }
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .disabled(isDisabled)
                                    .help(isDisabled ? "Max 8 devices selected." : "")
                                    
                                    Spacer()
                                    
                                    // Status Badge
                                    if let sel = appState.selectedDevices.first(where: { $0.id == id }) {
                                        switch sel.status {
                                        case .ok:
                                            Text("● ok").foregroundColor(.green).font(.caption)
                                        case .pairing:
                                            Text("◐ pairing").foregroundColor(.yellow).font(.caption)
                                        case .offline:
                                            Text("○ offline").foregroundColor(.gray).font(.caption)
                                        case .error:
                                            Text("⚠ error").foregroundColor(.red).font(.caption)
                                        }
                                    }
                                }
                                
                                // Error Details & Retry
                                if let sel = appState.selectedDevices.first(where: { $0.id == id }), case .error(let reason) = sel.status {
                                    HStack {
                                        Text("└ \(reason)").font(.caption).foregroundColor(.secondary)
                                        Button("Retry") {
                                            Task { await appState.engine.retry(deviceID: id) }
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                    }
                                    .padding(.leading, 24)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Text("\(appState.selectedDevices.count) of 8 selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(appState.airplayDevices.count) device(s) found")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

// Remove `selectedDeviceDisplayName` helper since it's no longer used.
```

- [ ] **Step 2: Commit**

```bash
git add Sources/AirBridge/MenuBar/SettingsView.swift
git commit -m "feat: SettingsView multi-select with status badges and limit"
```

---
