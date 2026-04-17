# AirBridge v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite AirBridge from a single-file AVPlayer-based audio relay to a queued, multipart-upload, per-engine-device-pinned playback system using AVAudioEngine.

**Architecture:** Replace AVPlayer with AVAudioEngine+AVAudioPlayerNode for per-engine output device pinning (verified by spike). Add PlaybackQueue actor for ordered track management with auto-advance. Switch from JSON path-based `/play` to multipart file upload via MultipartKit. Add full output device CRUD API. All state flows through AppState to SwiftUI.

**Tech Stack:** Swift 5.10+, macOS 14+, AVAudioEngine, CoreAudio, Hummingbird 2.x, MultipartKit, SwiftUI MenuBarExtra

**Spec:** `docs/design_v2.md`

---

## File Structure

### New Files
| Path | Responsibility |
|---|---|
| `Sources/AirBridge/Playback/PlaybackQueue.swift` | Queue actor: ordered tracks, auto-advance, reorder |
| `Sources/AirBridge/Playback/OutputDeviceObserver.swift` | CoreAudio listener for system default changes |
| `Sources/AirBridge/Transport/MultipartParser.swift` | MultipartKit helpers for file extraction |
| `Sources/AirBridge/Util/FileStaging.swift` | `~/.airbridge/queue/` file management |
| `Sources/AirBridge/MenuBar/QueueListView.swift` | Queue display in menu bar |
| `Tests/AirBridgeTests/PlaybackQueueTests.swift` | Queue actor unit tests |
| `Tests/AirBridgeTests/FileStagingTests.swift` | File staging unit tests |
| `Tests/AirBridgeTests/MultipartUploadTests.swift` | Multipart upload integration tests |

### Modified Files
| Path | Changes |
|---|---|
| `Package.swift` | Add `multipart-kit` dependency |
| `Sources/AirBridge/Playback/PlaybackEngine.swift` | Replace AVPlayer with AVAudioEngine+AVAudioPlayerNode, add device pinning |
| `Sources/AirBridge/Playback/PlaybackState.swift` | Add QueueTrack, QueueState, new DTOs |
| `Sources/AirBridge/Playback/AudioDeviceManager.swift` | Add UID-based API, remove setDefaultOutputDevice, add transport enum |
| `Sources/AirBridge/Playback/AudioValidator.swift` | Add `validateData` for in-memory validation |
| `Sources/AirBridge/Transport/APIRoutes.swift` | All new endpoints (queue, outputs, multipart) |
| `Sources/AirBridge/Transport/HTTPServer.swift` | Pass queue to router |
| `Sources/AirBridge/App/AppState.swift` | Add queue state, output UID tracking, observer |
| `Sources/AirBridge/MenuBar/MenuBarView.swift` | Queue display, engine target indicator |
| `Sources/AirBridge/MenuBar/SettingsView.swift` | UID-based device picker, migration |
| `Sources/AirBridge/Util/Logger.swift` | Add `queue` and `output` categories |
| `Tests/AirBridgeTests/PlaybackStateTests.swift` | Tests for new types |
| `Tests/AirBridgeTests/APIRoutesTests.swift` | Tests for new endpoints |

---

## Task 1: Add Logger Categories and Data Model Types

**Files:**
- Modify: `Sources/AirBridge/Util/Logger.swift`
- Modify: `Sources/AirBridge/Playback/PlaybackState.swift`
- Modify: `Tests/AirBridgeTests/PlaybackStateTests.swift`

- [ ] **Step 1: Add logger categories**

In `Sources/AirBridge/Util/Logger.swift`, add two new categories:

```swift
enum Log {
    static let http = Logger(subsystem: "com.gsmlg.airbridge", category: "http")
    static let playback = Logger(subsystem: "com.gsmlg.airbridge", category: "playback")
    static let server = Logger(subsystem: "com.gsmlg.airbridge", category: "server")
    static let queue = Logger(subsystem: "com.gsmlg.airbridge", category: "queue")
    static let output = Logger(subsystem: "com.gsmlg.airbridge", category: "output")
}
```

- [ ] **Step 2: Add QueueTrack and QueueState types**

In `Sources/AirBridge/Playback/PlaybackState.swift`, add after the existing `PlaybackState` enum:

```swift
struct QueueTrack: Identifiable, Sendable, Equatable {
    let id: UUID
    let originalFilename: String
    let stagedPath: String
    let addedAt: Date
    let mimeType: String?
}

struct QueueState: Sendable, Equatable {
    var tracks: [QueueTrack]
    var currentIndex: Int?

    init(tracks: [QueueTrack] = [], currentIndex: Int? = nil) {
        self.tracks = tracks
        self.currentIndex = currentIndex
    }

    var currentTrack: QueueTrack? {
        guard let idx = currentIndex, tracks.indices.contains(idx) else { return nil }
        return tracks[idx]
    }

    var isEmpty: Bool { tracks.isEmpty }
}
```

- [ ] **Step 3: Add AudioOutputDevice with UID**

In `Sources/AirBridge/Playback/PlaybackState.swift`, add the new device model:

```swift
enum AudioTransport: String, Sendable, Codable {
    case builtIn = "built_in"
    case usb
    case bluetooth
    case hdmi
    case airplay
    case virtual
    case other
}

struct AudioOutputDeviceInfo: Identifiable, Sendable, Equatable, Codable {
    let id: String              // UID — stable across reboots
    let name: String
    let transport: AudioTransport
    let isSystemDefault: Bool
    let isEngineTarget: Bool
}
```

- [ ] **Step 4: Add new API response DTOs**

In `Sources/AirBridge/Playback/PlaybackState.swift`, replace the existing DTOs with v2 versions. Keep `ErrorResponse` as-is. Replace/add:

```swift
struct EnqueueResponse: Codable, Sendable {
    let id: String
    let filename: String
    let position: Int
    let queue_length: Int
}

struct PlayNowResponse: Codable, Sendable {
    let id: String
    let filename: String
    let status: String
    let queue_length: Int
}

struct QueueListResponse: Codable, Sendable {
    let current_index: Int?
    let tracks: [TrackInfo]

    struct TrackInfo: Codable, Sendable {
        let id: String
        let filename: String
        let position: Int
        let status: String
    }
}

struct TrackActionResponse: Codable, Sendable {
    let status: String
    let track: TrackRef?

    struct TrackRef: Codable, Sendable {
        let id: String
        let filename: String
    }
}

struct RemoveResponse: Codable, Sendable {
    let removed: String
    let queue_length: Int
}

struct OutputsResponse: Codable, Sendable {
    let current_engine_target: String?
    let current_system_default: String?
    let current_airplay_route: String?
    let devices: [AudioOutputDeviceInfo]
}

struct OutputCurrentResponse: Codable, Sendable {
    let id: String
    let name: String
    let transport: String
    let hot_swapped: Bool?
}

struct StatusResponse: Codable, Sendable {
    let status: String
    let track: TrackRef?
    let queue_length: Int
    let queue_position: Int?
    let output: OutputInfo?
    let error: String?

    struct TrackRef: Codable, Sendable {
        let id: String
        let filename: String
    }

    struct OutputInfo: Codable, Sendable {
        let engine_target: String?
        let engine_target_name: String?
        let system_default: String?
        let airplay_route: String?
    }
}
```

Remove the old `PlayRequest`, `PlayResponse`, `StopResponse`, and old `StatusResponse` types.

- [ ] **Step 5: Write tests for new types**

Replace `Tests/AirBridgeTests/PlaybackStateTests.swift`:

```swift
import Testing
@testable import AirBridge

struct PlaybackStateTests {
    @Test func idleState_isNotPlaying() {
        let state = PlaybackState.idle
        #expect(!state.isPlaying)
        #expect(state.statusString == "idle")
    }

    @Test func playingState_isPlaying() {
        let state = PlaybackState.playing(file: "test.mp3")
        #expect(state.isPlaying)
        #expect(state.currentFile == "test.mp3")
    }

    @Test func errorState_hasMessage() {
        let state = PlaybackState.error(message: "fail")
        #expect(state.errorMessage == "fail")
        #expect(state.statusString == "error")
    }

    @Test func queueTrack_equatable() {
        let id = UUID()
        let t1 = QueueTrack(id: id, originalFilename: "a.mp3", stagedPath: "/tmp/a", addedAt: Date(), mimeType: "audio/mpeg")
        let t2 = QueueTrack(id: id, originalFilename: "a.mp3", stagedPath: "/tmp/a", addedAt: t1.addedAt, mimeType: "audio/mpeg")
        #expect(t1 == t2)
    }

    @Test func queueState_currentTrack() {
        let track = QueueTrack(id: UUID(), originalFilename: "a.mp3", stagedPath: "/tmp/a", addedAt: Date(), mimeType: nil)
        var state = QueueState(tracks: [track], currentIndex: 0)
        #expect(state.currentTrack?.id == track.id)
        state.currentIndex = nil
        #expect(state.currentTrack == nil)
    }

    @Test func queueState_empty() {
        let state = QueueState()
        #expect(state.isEmpty)
        #expect(state.currentTrack == nil)
    }

    @Test func audioTransport_rawValues() {
        #expect(AudioTransport.builtIn.rawValue == "built_in")
        #expect(AudioTransport.airplay.rawValue == "airplay")
    }

    @Test func enqueueResponse_encodesToJSON() throws {
        let resp = EnqueueResponse(id: "abc", filename: "test.mp3", position: 0, queue_length: 1)
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(EnqueueResponse.self, from: data)
        #expect(decoded.id == "abc")
        #expect(decoded.queue_length == 1)
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter PlaybackStateTests`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/AirBridge/Util/Logger.swift Sources/AirBridge/Playback/PlaybackState.swift Tests/AirBridgeTests/PlaybackStateTests.swift
git commit -m "feat: add v2 data model types, queue track/state, output device info, API DTOs"
```

---

## Task 2: Rewrite AudioDeviceManager with UID-Based API

**Files:**
- Modify: `Sources/AirBridge/Playback/AudioDeviceManager.swift`

- [ ] **Step 1: Rewrite AudioDeviceManager**

Replace the entire contents of `Sources/AirBridge/Playback/AudioDeviceManager.swift` with a UID-based, read-only API. No `setDefaultOutputDevice` — that's deliberately absent in v2.

```swift
import CoreAudio
import os

enum AudioDeviceManager {
    static func allOutputDevices(engineTargetUID: String? = nil) -> [AudioOutputDeviceInfo] {
        let deviceIDs = getOutputDeviceIDs()
        let defaultID = getDefaultOutputDeviceID()

        return deviceIDs.compactMap { devID -> AudioOutputDeviceInfo? in
            guard let uid = deviceUID(for: devID) else { return nil }
            let name = deviceName(for: devID)
            let transport = transportType(for: devID)

            return AudioOutputDeviceInfo(
                id: uid,
                name: name,
                transport: transport,
                isSystemDefault: devID == defaultID,
                isEngineTarget: uid == engineTargetUID
            )
        }.sorted { $0.name < $1.name }
    }

    static func getDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    static func deviceUID(for id: AudioDeviceID) -> String? {
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid)
        guard status == noErr, let cfStr = uid?.takeRetainedValue() else { return nil }
        return cfStr as String
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let deviceIDs = getOutputDeviceIDs()
        for devID in deviceIDs {
            if deviceUID(for: devID) == uid {
                return devID
            }
        }
        return nil
    }

    static func transportType(for id: AudioDeviceID) -> AudioTransport {
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rawTransport: UInt32 = 0
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rawTransport)

        switch rawTransport {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeHDMI: return .hdmi
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        case kAudioDeviceTransportTypeVirtual: return .virtual
        default: return .other
        }
    }

    // MARK: - Private

    private static func getOutputDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.filter { hasOutputChannels($0) }
    }

    private static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func deviceName(for id: AudioDeviceID) -> String {
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let cfStr = name?.takeRetainedValue() else { return "Unknown" }
        return cfStr as String
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`
Expected: Build succeeds (SettingsView will have errors — that's fine, we fix it in Task 9).

- [ ] **Step 3: Commit**

```bash
git add Sources/AirBridge/Playback/AudioDeviceManager.swift
git commit -m "refactor: rewrite AudioDeviceManager with UID-based read-only API"
```

---

## Task 3: Rewrite PlaybackEngine with AVAudioEngine

**Files:**
- Modify: `Sources/AirBridge/Playback/PlaybackEngine.swift`

- [ ] **Step 1: Rewrite PlaybackEngine**

Replace the entire contents of `Sources/AirBridge/Playback/PlaybackEngine.swift`. This replaces AVPlayer with AVAudioEngine+AVAudioPlayerNode with per-engine device pinning.

```swift
import AVFoundation
import CoreAudio
import os

actor PlaybackEngine {
    private(set) var state: PlaybackState = .idle

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var currentDeviceUID: String?
    private var stateCallback: (@Sendable (PlaybackState) -> Void)?
    private var trackFinishedCallback: (@Sendable () async -> Void)?

    func setStateCallback(_ callback: @escaping @Sendable (PlaybackState) -> Void) {
        self.stateCallback = callback
    }

    func setTrackFinishedCallback(_ callback: @escaping @Sendable () async -> Void) {
        self.trackFinishedCallback = callback
    }

    // MARK: - Output Device

    func setOutputDevice(uid: String) async throws -> Bool {
        let wasPlaying = state.isPlaying
        let oldUID = currentDeviceUID

        guard let deviceID = AudioDeviceManager.deviceID(forUID: uid) else {
            throw PlaybackEngineError.deviceNotFound(uid: uid)
        }

        if engine == nil {
            setupEngine()
        }

        guard let engine = engine else {
            throw PlaybackEngineError.engineSetupFailed
        }

        let audioUnit = engine.outputNode.audioUnit!
        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw PlaybackEngineError.deviceUnavailable(uid: uid)
        }

        currentDeviceUID = uid

        let hotSwapped = wasPlaying && oldUID != nil && oldUID != uid
        if hotSwapped {
            do {
                try engine.start()
                playerNode?.play()
            } catch {
                transition(to: .error(message: "Failed to restart after device swap: \(error.localizedDescription)"))
                throw PlaybackEngineError.engineSetupFailed
            }
        }

        Log.output.info("Output device set to \(uid, privacy: .public), hot_swapped=\(hotSwapped)")
        return hotSwapped
    }

    var outputDeviceUID: String? { currentDeviceUID }

    // MARK: - Playback

    func play(track: QueueTrack) async throws {
        stopInternal()
        setupEngine()

        guard let engine = engine, let playerNode = playerNode else {
            transition(to: .error(message: "Audio engine setup failed"))
            throw PlaybackEngineError.engineSetupFailed
        }

        // Pin to saved device if set
        if let uid = currentDeviceUID, let deviceID = AudioDeviceManager.deviceID(forUID: uid) {
            let audioUnit = engine.outputNode.audioUnit!
            var devID = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: track.stagedPath))
            self.audioFile = file

            engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)

            try engine.start()

            playerNode.scheduleFile(file, at: nil) { [weak self] in
                guard let self else { return }
                Task {
                    await self.handlePlaybackFinished()
                }
            }
            playerNode.play()

            transition(to: .playing(file: track.originalFilename))
            Log.playback.info("Playing: \(track.originalFilename, privacy: .public)")
        } catch {
            transition(to: .error(message: "Playback failed: \(error.localizedDescription)"))
            throw error
        }
    }

    func stop() -> PlaybackState {
        stopInternal()
        transition(to: .idle)
        return state
    }

    func pause() -> PlaybackState {
        guard case .playing(let file) = state else { return state }
        playerNode?.pause()
        engine?.pause()
        transition(to: .paused(file: file))
        return state
    }

    func resume() -> PlaybackState {
        guard case .paused = state, let engine = engine, let playerNode = playerNode else { return state }
        do {
            try engine.start()
            playerNode.play()
            if case .paused(let file) = state {
                transition(to: .playing(file: file))
            }
        } catch {
            transition(to: .error(message: "Resume failed: \(error.localizedDescription)"))
        }
        return state
    }

    // MARK: - Private

    private func setupEngine() {
        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        self.engine = eng
        self.playerNode = node
    }

    private func stopInternal() {
        playerNode?.stop()
        engine?.stop()
        engine?.reset()
        playerNode = nil
        engine = nil
        audioFile = nil
    }

    private func handlePlaybackFinished() {
        guard state.isPlaying else { return }
        transition(to: .idle)
        Log.playback.info("Track finished")

        if let cb = trackFinishedCallback {
            Task { await cb() }
        }
    }

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
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Compilation errors in `AppState.swift` and `APIRoutes.swift` because the engine API changed. That's expected — we'll fix those in later tasks.

- [ ] **Step 3: Commit**

```bash
git add Sources/AirBridge/Playback/PlaybackEngine.swift
git commit -m "feat: rewrite PlaybackEngine with AVAudioEngine and per-engine device pinning"
```

---

## Task 4: FileStaging

**Files:**
- Create: `Sources/AirBridge/Util/FileStaging.swift`
- Create: `Tests/AirBridgeTests/FileStagingTests.swift`

- [ ] **Step 1: Write tests for FileStaging**

Create `Tests/AirBridgeTests/FileStagingTests.swift`:

```swift
import Foundation
import Testing
@testable import AirBridge

struct FileStagingTests {
    @Test func stage_createsFileWithUUIDName() throws {
        let data = Data("test audio data".utf8)
        let (url, id) = try FileStaging.stage(data: data, filename: "hello.mp3")
        defer { FileStaging.remove(url: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "mp3")
        #expect(url.lastPathComponent.contains(id.uuidString))
    }

    @Test func stage_preservesExtension() throws {
        let data = Data("wav data".utf8)
        let (url, _) = try FileStaging.stage(data: data, filename: "song.wav")
        defer { FileStaging.remove(url: url) }

        #expect(url.pathExtension == "wav")
    }

    @Test func stage_noExtension_usesEmptyExtension() throws {
        let data = Data("data".utf8)
        let (url, _) = try FileStaging.stage(data: data, filename: "noext")
        defer { FileStaging.remove(url: url) }

        #expect(url.pathExtension == "")
    }

    @Test func remove_deletesFile() throws {
        let data = Data("delete me".utf8)
        let (url, _) = try FileStaging.stage(data: data, filename: "temp.mp3")
        FileStaging.remove(url: url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func clearAll_removesAllFiles() throws {
        let data = Data("data".utf8)
        let (url1, _) = try FileStaging.stage(data: data, filename: "a.mp3")
        let (url2, _) = try FileStaging.stage(data: data, filename: "b.mp3")

        FileStaging.clearAll()

        #expect(!FileManager.default.fileExists(atPath: url1.path))
        #expect(!FileManager.default.fileExists(atPath: url2.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter FileStagingTests`
Expected: Compilation error — `FileStaging` not defined.

- [ ] **Step 3: Implement FileStaging**

Create `Sources/AirBridge/Util/FileStaging.swift`:

```swift
import Foundation
import os

enum FileStaging {
    static var directory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".airbridge")
            .appendingPathComponent("queue")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func stage(data: Data, filename: String) throws -> (URL, UUID) {
        let id = UUID()
        let ext = (filename as NSString).pathExtension
        let name = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        Log.queue.info("Staged \(filename, privacy: .public) → \(url.lastPathComponent, privacy: .public)")
        return (url, id)
    }

    static func remove(url: URL) {
        try? FileManager.default.removeItem(at: url)
        Log.queue.info("Removed staged file: \(url.lastPathComponent, privacy: .public)")
    }

    static func clearAll() {
        let dir = directory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        Log.queue.info("Cleared all staged files")
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter FileStagingTests`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AirBridge/Util/FileStaging.swift Tests/AirBridgeTests/FileStagingTests.swift
git commit -m "feat: add FileStaging for queue file management"
```

---

## Task 5: PlaybackQueue Actor

**Files:**
- Create: `Sources/AirBridge/Playback/PlaybackQueue.swift`
- Create: `Tests/AirBridgeTests/PlaybackQueueTests.swift`

- [ ] **Step 1: Write queue tests**

Create `Tests/AirBridgeTests/PlaybackQueueTests.swift`:

```swift
import Foundation
import Testing
@testable import AirBridge

struct PlaybackQueueTests {
    private func makeTrack(filename: String = "test.mp3") -> QueueTrack {
        QueueTrack(
            id: UUID(),
            originalFilename: filename,
            stagedPath: "/tmp/\(UUID().uuidString).mp3",
            addedAt: Date(),
            mimeType: "audio/mpeg"
        )
    }

    @Test func enqueue_addsTrack() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let track = makeTrack()
        let (id, position) = await queue.enqueue(track: track)
        #expect(id == track.id)
        #expect(position == 0)

        let state = await queue.list()
        #expect(state.tracks.count == 1)
    }

    @Test func enqueue_multipleTracksPreservesOrder() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let t1 = makeTrack(filename: "a.mp3")
        let t2 = makeTrack(filename: "b.mp3")
        let t3 = makeTrack(filename: "c.mp3")

        let (_, p1) = await queue.enqueue(track: t1)
        let (_, p2) = await queue.enqueue(track: t2)
        let (_, p3) = await queue.enqueue(track: t3)

        #expect(p1 == 0)
        #expect(p2 == 1)
        #expect(p3 == 2)

        let state = await queue.list()
        #expect(state.tracks.map(\.originalFilename) == ["a.mp3", "b.mp3", "c.mp3"])
    }

    @Test func remove_deletesTrack() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let track = makeTrack()
        _ = await queue.enqueue(track: track)

        let removed = await queue.remove(id: track.id)
        #expect(removed)

        let state = await queue.list()
        #expect(state.tracks.isEmpty)
    }

    @Test func remove_nonexistentReturnsFalse() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let removed = await queue.remove(id: UUID())
        #expect(!removed)
    }

    @Test func move_reordersTrack() async throws {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let t1 = makeTrack(filename: "a.mp3")
        let t2 = makeTrack(filename: "b.mp3")
        let t3 = makeTrack(filename: "c.mp3")
        _ = await queue.enqueue(track: t1)
        _ = await queue.enqueue(track: t2)
        _ = await queue.enqueue(track: t3)

        try await queue.move(id: t3.id, toPosition: 0)

        let state = await queue.list()
        #expect(state.tracks.map(\.originalFilename) == ["c.mp3", "a.mp3", "b.mp3"])
    }

    @Test func clear_removesAllTracks() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        _ = await queue.enqueue(track: makeTrack(filename: "a.mp3"))
        _ = await queue.enqueue(track: makeTrack(filename: "b.mp3"))

        await queue.clear()

        let state = await queue.list()
        #expect(state.tracks.isEmpty)
        #expect(state.currentIndex == nil)
    }

    @Test func list_returnsCurrentState() async {
        let queue = PlaybackQueue(engine: PlaybackEngine())
        let state = await queue.list()
        #expect(state.isEmpty)
        #expect(state.currentIndex == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PlaybackQueueTests`
Expected: Compilation error — `PlaybackQueue` not defined.

- [ ] **Step 3: Implement PlaybackQueue**

Create `Sources/AirBridge/Playback/PlaybackQueue.swift`:

```swift
import Foundation
import os

actor PlaybackQueue {
    private var state = QueueState()
    private let engine: PlaybackEngine

    init(engine: PlaybackEngine) {
        self.engine = engine

        Task {
            await engine.setTrackFinishedCallback { [weak self] in
                guard let self else { return }
                await self.advanceToNext()
            }
        }
    }

    func enqueue(track: QueueTrack) async -> (id: UUID, position: Int) {
        state.tracks.append(track)
        let position = state.tracks.count - 1
        Log.queue.info("Enqueued '\(track.originalFilename, privacy: .public)' at position \(position)")

        // Auto-start if queue was idle
        if state.currentIndex == nil {
            state.currentIndex = 0
            await playCurrentTrack()
        }

        return (track.id, position)
    }

    func playNow(track: QueueTrack) async {
        let insertIndex = (state.currentIndex ?? -1) + 1
        state.tracks.insert(track, at: insertIndex)
        state.currentIndex = insertIndex
        Log.queue.info("Play now: '\(track.originalFilename, privacy: .public)' at position \(insertIndex)")
        await playCurrentTrack()
    }

    func remove(id: UUID) async -> Bool {
        guard let idx = state.tracks.firstIndex(where: { $0.id == id }) else {
            return false
        }

        let track = state.tracks[idx]
        let isCurrentTrack = state.currentIndex == idx

        state.tracks.remove(at: idx)
        FileStaging.remove(url: URL(fileURLWithPath: track.stagedPath))

        // Adjust currentIndex
        if let current = state.currentIndex {
            if idx < current {
                state.currentIndex = current - 1
            } else if idx == current {
                // Removed current track — advance or go idle
                if isCurrentTrack {
                    _ = await engine.stop()
                    if state.tracks.isEmpty {
                        state.currentIndex = nil
                    } else {
                        state.currentIndex = min(current, state.tracks.count - 1)
                        await playCurrentTrack()
                    }
                }
            }
        }

        Log.queue.info("Removed '\(track.originalFilename, privacy: .public)'")
        return true
    }

    func move(id: UUID, toPosition: Int) async throws {
        guard let fromIdx = state.tracks.firstIndex(where: { $0.id == id }) else {
            throw QueueError.trackNotFound
        }
        let clampedTo = max(0, min(toPosition, state.tracks.count - 1))
        let track = state.tracks.remove(at: fromIdx)
        state.tracks.insert(track, at: clampedTo)

        // Adjust currentIndex to keep the playing track stable
        if let current = state.currentIndex {
            if track.id == state.tracks[safe: current]?.id {
                // No adjustment needed
            } else if let newCurrentIdx = state.tracks.firstIndex(where: { $0.id == state.currentTrack?.id }) {
                state.currentIndex = newCurrentIdx
            }
        }

        Log.queue.info("Moved '\(track.originalFilename, privacy: .public)' to position \(clampedTo)")
    }

    func clear() async {
        _ = await engine.stop()
        for track in state.tracks {
            FileStaging.remove(url: URL(fileURLWithPath: track.stagedPath))
        }
        state = QueueState()
        Log.queue.info("Queue cleared")
    }

    func next() async -> QueueTrack? {
        guard let current = state.currentIndex, current + 1 < state.tracks.count else {
            return nil
        }
        state.currentIndex = current + 1
        await playCurrentTrack()
        return state.currentTrack
    }

    func previous() async -> QueueTrack? {
        guard let current = state.currentIndex else { return nil }
        if current > 0 {
            state.currentIndex = current - 1
        }
        // At position 0, restart current track
        await playCurrentTrack()
        return state.currentTrack
    }

    func list() -> QueueState {
        state
    }

    // MARK: - Private

    private func advanceToNext() async {
        guard let current = state.currentIndex else { return }
        let nextIdx = current + 1
        if nextIdx < state.tracks.count {
            state.currentIndex = nextIdx
            await playCurrentTrack()
        } else {
            state.currentIndex = nil
            Log.queue.info("Queue exhausted")
        }
    }

    private func playCurrentTrack() async {
        guard let track = state.currentTrack else { return }
        do {
            try await engine.play(track: track)
        } catch {
            Log.playback.error("Failed to play '\(track.originalFilename, privacy: .public)': \(error)")
        }
    }
}

enum QueueError: Error, Sendable {
    case trackNotFound
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PlaybackQueueTests`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AirBridge/Playback/PlaybackQueue.swift Tests/AirBridgeTests/PlaybackQueueTests.swift
git commit -m "feat: add PlaybackQueue actor with ordering, auto-advance, reorder"
```

---

## Task 6: OutputDeviceObserver

**Files:**
- Create: `Sources/AirBridge/Playback/OutputDeviceObserver.swift`

- [ ] **Step 1: Implement OutputDeviceObserver**

Create `Sources/AirBridge/Playback/OutputDeviceObserver.swift`:

```swift
import CoreAudio
import os

final class OutputDeviceObserver: Sendable {
    private let callback: @Sendable (AudioDeviceID) -> Void

    init(onChange callback: @escaping @Sendable (AudioDeviceID) -> Void) {
        self.callback = callback
        startListening()
    }

    private func startListening() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let selfPtr = Unmanaged.passRetained(self).toOpaque()
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            outputDeviceChanged,
            selfPtr
        )
        Log.output.info("OutputDeviceObserver started")
    }

    func stopListening() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            outputDeviceChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        Log.output.info("OutputDeviceObserver stopped")
    }

    deinit {
        stopListening()
    }
}

private func outputDeviceChanged(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let observer = Unmanaged<OutputDeviceObserver>.fromOpaque(clientData).takeUnretainedValue()
    let newDefault = AudioDeviceManager.getDefaultOutputDeviceID()
    Log.output.info("System default output changed to device ID \(newDefault)")
    observer.callback(newDefault)
    return noErr
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: Compiles (may have errors in other files that haven't been updated yet — that's expected).

- [ ] **Step 3: Commit**

```bash
git add Sources/AirBridge/Playback/OutputDeviceObserver.swift
git commit -m "feat: add OutputDeviceObserver for system default changes"
```

---

## Task 7: MultipartParser and Package.swift Update

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AirBridge/Transport/MultipartParser.swift`

- [ ] **Step 1: Add multipart-kit dependency**

Update `Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AirBridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/multipart-kit.git", from: "4.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "AirBridge",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MultipartKit", package: "multipart-kit"),
            ],
            path: "Sources/AirBridge"
        ),
        .testTarget(
            name: "AirBridgeTests",
            dependencies: [
                "AirBridge",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/AirBridgeTests"
        ),
    ]
)
```

- [ ] **Step 2: Resolve dependencies**

Run: `swift package resolve`
Expected: multipart-kit downloads successfully.

- [ ] **Step 3: Implement MultipartParser**

Create `Sources/AirBridge/Transport/MultipartParser.swift`:

```swift
import Foundation
import Hummingbird
import MultipartKit
import os

enum MultipartParser {
    struct UploadedFile {
        let filename: String
        let data: Data
        let contentType: String?
    }

    static func extractFile(from request: Request, context: BasicRequestContext) async throws -> UploadedFile {
        guard let contentType = request.headers[.contentType],
              contentType.contains("multipart/form-data") else {
            throw MultipartError.notMultipart
        }

        // Extract boundary from content-type header
        guard let boundary = extractBoundary(from: contentType) else {
            throw MultipartError.noBoundary
        }

        let body = try await request.body.collect(upTo: 50 * 1024 * 1024) // 50 MB
        let bodyData = Data(buffer: body)

        let parts = try FormDataDecoder().decode(FileUpload.self, from: bodyData, boundary: boundary)

        guard let file = parts.file else {
            throw MultipartError.noFileField
        }

        guard !file.data.readableBytes == false, file.data.readableBytes > 0 else {
            throw MultipartError.emptyFile
        }

        let filename = file.filename ?? "upload"
        let data = Data(buffer: file.data)

        Log.http.info("Parsed multipart upload: \(filename, privacy: .public), \(data.count) bytes")

        return UploadedFile(
            filename: filename,
            data: data,
            contentType: file.contentType?.description
        )
    }

    private static func extractBoundary(from contentType: String) -> String? {
        let parts = contentType.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("boundary=") {
                var boundary = String(trimmed.dropFirst("boundary=".count))
                // Remove quotes if present
                if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
                    boundary = String(boundary.dropFirst().dropLast())
                }
                return boundary
            }
        }
        return nil
    }
}

struct FileUpload: Decodable {
    var file: FormFile?
}

struct FormFile: Decodable {
    let data: ByteBuffer
    let filename: String?
    let contentType: HTTPMediaType?

    enum CodingKeys: String, CodingKey {
        case data, filename, contentType
    }
}

enum MultipartError: Error, Sendable {
    case notMultipart
    case noBoundary
    case noFileField
    case emptyFile
    case tooLarge

    var errorCode: String {
        switch self {
        case .notMultipart: return "not_multipart"
        case .noBoundary: return "invalid_multipart"
        case .noFileField: return "missing_file_field"
        case .emptyFile: return "empty_file"
        case .tooLarge: return "file_too_large"
        }
    }
}
```

> **Note:** The exact MultipartKit API may need adjustment — MultipartKit's `FormDataDecoder` API varies between versions. The implementer should check the MultipartKit docs and adjust the parsing logic. The key contract is: extract a file named "file" from the multipart body, return its data, filename, and content type.

- [ ] **Step 4: Build**

Run: `swift build`
Expected: Compiles. If MultipartKit API differs, adjust accordingly.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/AirBridge/Transport/MultipartParser.swift
git commit -m "feat: add MultipartKit dependency and MultipartParser"
```

---

## Task 8: Rewrite APIRoutes with All v2 Endpoints

**Files:**
- Modify: `Sources/AirBridge/Transport/APIRoutes.swift`
- Modify: `Sources/AirBridge/Transport/HTTPServer.swift`
- Modify: `Tests/AirBridgeTests/APIRoutesTests.swift`

- [ ] **Step 1: Update HTTPServer**

Replace `Sources/AirBridge/Transport/HTTPServer.swift`:

```swift
import Hummingbird
import os

func buildApplication(
    engine: PlaybackEngine,
    queue: PlaybackQueue,
    appState: AppState?,
    address: String,
    port: Int,
    authToken: String
) throws -> some ApplicationProtocol {
    let router = buildRouter(engine: engine, queue: queue, appState: appState, authToken: authToken)
    let app = Application(router: router, configuration: .init(address: .hostname(address, port: port)))
    Log.server.info("Server configured on \(address, privacy: .public):\(port)")
    return app
}
```

- [ ] **Step 2: Rewrite APIRoutes**

Replace `Sources/AirBridge/Transport/APIRoutes.swift` with all v2 endpoints:

```swift
import Foundation
import Hummingbird
import os

// MARK: - Auth Middleware

struct AuthMiddleware: RouterMiddleware {
    let token: String

    func handle(
        _ request: Request,
        context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let auth = request.headers[.authorization] else {
            Log.http.warning("Missing auth token")
            return try jsonResponse(ErrorResponse(error: "unauthorized", message: "Missing auth token"), status: .unauthorized)
        }
        guard auth == "Bearer \(token)" else {
            Log.http.warning("Invalid auth token")
            return try jsonResponse(ErrorResponse(error: "unauthorized", message: "Invalid auth token"), status: .unauthorized)
        }
        return try await next(request, context)
    }
}

// MARK: - Router

func buildRouter(
    engine: PlaybackEngine,
    queue: PlaybackQueue,
    appState: AppState?,
    authToken: String = ""
) -> Router<BasicRequestContext> {
    let router = Router()

    if !authToken.isEmpty {
        router.add(middleware: AuthMiddleware(token: authToken))
    }

    // GET /status
    router.get("status") { _, _ -> Response in
        let engineState = await engine.state
        let queueState = await queue.list()
        let engineUID = await engine.outputDeviceUID

        let track: StatusResponse.TrackRef? = queueState.currentTrack.map {
            .init(id: $0.id.uuidString, filename: $0.originalFilename)
        }

        let defaultUID = AudioDeviceManager.deviceUID(for: AudioDeviceManager.getDefaultOutputDeviceID())
        let devices = AudioDeviceManager.allOutputDevices(engineTargetUID: engineUID)
        let engineDevice = devices.first { $0.isEngineTarget }
        let defaultDevice = devices.first { $0.isSystemDefault }
        let airplayRoute: String? = defaultDevice?.transport == .airplay ? defaultDevice?.name : nil

        let resp = StatusResponse(
            status: engineState.statusString,
            track: track,
            queue_length: queueState.tracks.count,
            queue_position: queueState.currentIndex,
            output: StatusResponse.OutputInfo(
                engine_target: engineUID,
                engine_target_name: engineDevice?.name,
                system_default: defaultUID,
                airplay_route: airplayRoute
            ),
            error: engineState.errorMessage
        )
        return try jsonResponse(resp)
    }

    // POST /queue — enqueue via multipart
    router.post("queue") { request, context -> Response in
        do {
            let upload = try await MultipartParser.extractFile(from: request, context: context)

            // Validate extension
            let ext = (upload.filename as NSString).pathExtension.lowercased()
            guard AudioValidator.supportedExtensions.contains(ext) else {
                return try jsonResponse(
                    ErrorResponse(error: "unsupported_format", message: "Unsupported format: \(ext)"),
                    status: .badRequest
                )
            }

            let (url, id) = try FileStaging.stage(data: upload.data, filename: upload.filename)
            let track = QueueTrack(
                id: id,
                originalFilename: upload.filename,
                stagedPath: url.path,
                addedAt: Date(),
                mimeType: upload.contentType
            )

            let (_, position) = await queue.enqueue(track: track)
            let queueState = await queue.list()

            return try jsonResponse(EnqueueResponse(
                id: id.uuidString,
                filename: upload.filename,
                position: position,
                queue_length: queueState.tracks.count
            ))
        } catch let error as MultipartError {
            return try jsonResponse(
                ErrorResponse(error: error.errorCode, message: "\(error)"),
                status: .badRequest
            )
        }
    }

    // POST /play — upload and play immediately
    router.post("play") { request, context -> Response in
        do {
            let upload = try await MultipartParser.extractFile(from: request, context: context)

            let ext = (upload.filename as NSString).pathExtension.lowercased()
            guard AudioValidator.supportedExtensions.contains(ext) else {
                return try jsonResponse(
                    ErrorResponse(error: "unsupported_format", message: "Unsupported format: \(ext)"),
                    status: .badRequest
                )
            }

            let (url, id) = try FileStaging.stage(data: upload.data, filename: upload.filename)
            let track = QueueTrack(
                id: id,
                originalFilename: upload.filename,
                stagedPath: url.path,
                addedAt: Date(),
                mimeType: upload.contentType
            )

            await queue.playNow(track: track)
            let queueState = await queue.list()

            return try jsonResponse(PlayNowResponse(
                id: id.uuidString,
                filename: upload.filename,
                status: "playing",
                queue_length: queueState.tracks.count
            ))
        } catch let error as MultipartError {
            return try jsonResponse(
                ErrorResponse(error: error.errorCode, message: "\(error)"),
                status: .badRequest
            )
        }
    }

    // GET /queue
    router.get("queue") { _, _ -> Response in
        let queueState = await queue.list()
        let tracks = queueState.tracks.enumerated().map { (idx, track) -> QueueListResponse.TrackInfo in
            let status: String
            if let current = queueState.currentIndex {
                if idx < current { status = "played" }
                else if idx == current { status = "playing" }
                else { status = "queued" }
            } else {
                status = "queued"
            }
            return QueueListResponse.TrackInfo(
                id: track.id.uuidString,
                filename: track.originalFilename,
                position: idx,
                status: status
            )
        }
        return try jsonResponse(QueueListResponse(current_index: queueState.currentIndex, tracks: tracks))
    }

    // DELETE /queue/:id
    router.delete("queue/:id") { _, context -> Response in
        guard let idString = context.parameters.get("id"),
              let id = UUID(uuidString: idString) else {
            return try jsonResponse(
                ErrorResponse(error: "invalid_id", message: "Invalid track ID"),
                status: .badRequest
            )
        }
        let removed = await queue.remove(id: id)
        guard removed else {
            return try jsonResponse(
                ErrorResponse(error: "not_found", message: "Track not found"),
                status: .notFound
            )
        }
        let queueState = await queue.list()
        return try jsonResponse(RemoveResponse(removed: idString, queue_length: queueState.tracks.count))
    }

    // POST /queue/next
    router.post("queue/next") { _, _ -> Response in
        guard let track = await queue.next() else {
            return try jsonResponse(
                ErrorResponse(error: "queue_end", message: "No next track"),
                status: .badRequest
            )
        }
        return try jsonResponse(TrackActionResponse(
            status: "playing",
            track: .init(id: track.id.uuidString, filename: track.originalFilename)
        ))
    }

    // POST /queue/prev
    router.post("queue/prev") { _, _ -> Response in
        guard let track = await queue.previous() else {
            return try jsonResponse(
                ErrorResponse(error: "queue_empty", message: "Queue is empty"),
                status: .badRequest
            )
        }
        return try jsonResponse(TrackActionResponse(
            status: "playing",
            track: .init(id: track.id.uuidString, filename: track.originalFilename)
        ))
    }

    // POST /queue/move
    router.post("queue/move") { request, context -> Response in
        struct MoveRequest: Decodable {
            let id: String
            let position: Int
        }
        let body = try await request.decode(as: MoveRequest.self, context: context)
        guard let trackID = UUID(uuidString: body.id) else {
            return try jsonResponse(
                ErrorResponse(error: "invalid_id", message: "Invalid track ID"),
                status: .badRequest
            )
        }
        do {
            try await queue.move(id: trackID, toPosition: body.position)
            return try jsonResponse(["status": "ok"])
        } catch {
            return try jsonResponse(
                ErrorResponse(error: "not_found", message: "Track not found"),
                status: .notFound
            )
        }
    }

    // POST /pause
    router.post("pause") { _, _ -> Response in
        let state = await engine.pause()
        return try jsonResponse(["status": state.statusString])
    }

    // POST /resume
    router.post("resume") { _, _ -> Response in
        let state = await engine.resume()
        return try jsonResponse(["status": state.statusString])
    }

    // POST /stop
    router.post("stop") { _, _ -> Response in
        await queue.clear()
        return try jsonResponse(["status": "idle"])
    }

    // GET /outputs
    router.get("outputs") { _, _ -> Response in
        let engineUID = await engine.outputDeviceUID
        let devices = AudioDeviceManager.allOutputDevices(engineTargetUID: engineUID)
        let defaultUID = AudioDeviceManager.deviceUID(for: AudioDeviceManager.getDefaultOutputDeviceID())
        let defaultDevice = devices.first { $0.isSystemDefault }
        let airplayRoute: String? = defaultDevice?.transport == .airplay ? defaultDevice?.name : nil

        return try jsonResponse(OutputsResponse(
            current_engine_target: engineUID,
            current_system_default: defaultUID,
            current_airplay_route: airplayRoute,
            devices: devices
        ))
    }

    // GET /outputs/current
    router.get("outputs/current") { _, _ -> Response in
        let engineUID = await engine.outputDeviceUID
        guard let uid = engineUID else {
            // Return system default
            let defaultID = AudioDeviceManager.getDefaultOutputDeviceID()
            let defaultUID = AudioDeviceManager.deviceUID(for: defaultID) ?? ""
            let devices = AudioDeviceManager.allOutputDevices()
            let dev = devices.first { $0.isSystemDefault }
            return try jsonResponse(OutputCurrentResponse(
                id: defaultUID,
                name: dev?.name ?? "Unknown",
                transport: dev?.transport.rawValue ?? "other",
                hot_swapped: nil
            ))
        }
        let devices = AudioDeviceManager.allOutputDevices(engineTargetUID: uid)
        let dev = devices.first { $0.id == uid }
        return try jsonResponse(OutputCurrentResponse(
            id: uid,
            name: dev?.name ?? "Unknown",
            transport: dev?.transport.rawValue ?? "other",
            hot_swapped: nil
        ))
    }

    // PUT /outputs/current
    router.put("outputs/current") { request, context -> Response in
        struct SetOutputRequest: Decodable {
            let id: String
        }
        let body = try await request.decode(as: SetOutputRequest.self, context: context)

        do {
            let hotSwapped = try await engine.setOutputDevice(uid: body.id)

            // Persist
            if let appState {
                await MainActor.run {
                    UserDefaults.standard.set(body.id, forKey: "engineOutputDeviceUID")
                }
            }

            let devices = AudioDeviceManager.allOutputDevices(engineTargetUID: body.id)
            let dev = devices.first { $0.id == body.id }

            return try jsonResponse(OutputCurrentResponse(
                id: body.id,
                name: dev?.name ?? "Unknown",
                transport: dev?.transport.rawValue ?? "other",
                hot_swapped: hotSwapped
            ))
        } catch PlaybackEngineError.deviceNotFound {
            return try jsonResponse(
                ErrorResponse(error: "device_not_found", message: "Device not found: \(body.id)"),
                status: .notFound
            )
        } catch PlaybackEngineError.deviceUnavailable {
            return try jsonResponse(
                ErrorResponse(error: "device_unavailable", message: "Device unavailable: \(body.id)"),
                status: .badRequest
            )
        }
    }

    return router
}

// MARK: - Helpers

private func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONEncoder().encode(value)
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: .init(data: data))
    )
}

// MARK: - Test Application

func buildTestApplication(
    engine: PlaybackEngine,
    queue: PlaybackQueue? = nil,
    authToken: String = ""
) throws -> some ApplicationProtocol {
    let q = queue ?? PlaybackQueue(engine: engine)
    let router = buildRouter(engine: engine, queue: q, appState: nil, authToken: authToken)
    return Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
}
```

- [ ] **Step 3: Update API tests**

Replace `Tests/AirBridgeTests/APIRoutesTests.swift`:

```swift
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import AirBridge

struct APIRoutesTests {
    @Test func statusEndpoint_returnsIdleByDefault() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/status", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"status\":\"idle\""))
            }
        }
    }

    @Test func stopEndpoint_returnsIdle() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/stop", method: .post) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"status\":\"idle\""))
            }
        }
    }

    @Test func queueEndpoint_returnsEmptyQueue() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/queue", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"tracks\":[]"))
            }
        }
    }

    @Test func outputsEndpoint_returnsDevices() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/outputs", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"devices\""))
            }
        }
    }

    @Test func outputsCurrentEndpoint_returnsDevice() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/outputs/current", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("\"name\""))
            }
        }
    }

    @Test func deleteQueueTrack_notFound() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(
                uri: "/queue/\(UUID().uuidString)",
                method: .delete
            ) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test func pauseEndpoint_returnsStatus() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine())
        try await app.test(.live) { client in
            try await client.execute(uri: "/pause", method: .post) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test func authEnabled_validToken_returns200() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine(), authToken: "secret")
        try await app.test(.live) { client in
            try await client.execute(
                uri: "/status",
                method: .get,
                headers: [.authorization: "Bearer secret"]
            ) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test func authEnabled_missingToken_returns401() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine(), authToken: "secret")
        try await app.test(.live) { client in
            try await client.execute(uri: "/status", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test func authEnabled_wrongToken_returns401() async throws {
        let app = try buildTestApplication(engine: PlaybackEngine(), authToken: "secret")
        try await app.test(.live) { client in
            try await client.execute(
                uri: "/status",
                method: .get,
                headers: [.authorization: "Bearer wrong"]
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter APIRoutesTests`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AirBridge/Transport/APIRoutes.swift Sources/AirBridge/Transport/HTTPServer.swift Tests/AirBridgeTests/APIRoutesTests.swift
git commit -m "feat: rewrite API routes with queue, multipart upload, and output device endpoints"
```

---

## Task 9: Update AppState and Settings Migration

**Files:**
- Modify: `Sources/AirBridge/App/AppState.swift`
- Modify: `Sources/AirBridge/MenuBar/SettingsView.swift`

- [ ] **Step 1: Rewrite AppState**

Replace `Sources/AirBridge/App/AppState.swift`:

```swift
import Foundation
import Hummingbird
import SwiftUI
import os

@MainActor
final class AppState: ObservableObject {
    @Published var playbackState: PlaybackState = .idle
    @Published var queueState: QueueState = QueueState()
    @Published var currentOutputName: String = "System Default"
    @Published var currentOutputUID: String = ""

    let listenAddress: String
    let serverPort: Int
    let authToken: String

    let engine = PlaybackEngine()
    let queue: PlaybackQueue
    private var deviceObserver: OutputDeviceObserver?

    init() {
        // Migrate v1 settings if needed
        Self.migrateV1Settings()

        self.listenAddress = UserDefaults.standard.string(forKey: "listenAddress") ?? "127.0.0.1"
        let portStr = UserDefaults.standard.string(forKey: "serverPort") ?? "9876"
        self.serverPort = Int(portStr) ?? 9876
        self.authToken = UserDefaults.standard.string(forKey: "authToken") ?? ""

        self.queue = PlaybackQueue(engine: engine)

        // Restore saved output device
        let savedUID = UserDefaults.standard.string(forKey: "engineOutputDeviceUID") ?? ""
        if !savedUID.isEmpty {
            self.currentOutputUID = savedUID
            Task {
                do {
                    _ = try await engine.setOutputDevice(uid: savedUID)
                    let devices = AudioDeviceManager.allOutputDevices(engineTargetUID: savedUID)
                    if let dev = devices.first(where: { $0.id == savedUID }) {
                        self.currentOutputName = dev.name
                    }
                } catch {
                    Log.output.error("Failed to restore output device \(savedUID, privacy: .public): \(error)")
                }
            }
        }

        // State callback
        Task {
            await engine.setStateCallback { [weak self] newState in
                Task { @MainActor in
                    self?.playbackState = newState
                }
            }
        }

        // Device observer
        let followDefault = UserDefaults.standard.bool(forKey: "followSystemDefault")
        self.deviceObserver = OutputDeviceObserver { [weak self] newDefaultID in
            Task { @MainActor in
                guard let self else { return }
                if followDefault {
                    if let uid = AudioDeviceManager.deviceUID(for: newDefaultID) {
                        do {
                            _ = try await self.engine.setOutputDevice(uid: uid)
                            self.currentOutputUID = uid
                            self.currentOutputName = AudioDeviceManager.allOutputDevices().first { $0.isSystemDefault }?.name ?? "Unknown"
                            UserDefaults.standard.set(uid, forKey: "engineOutputDeviceUID")
                        } catch {
                            Log.output.error("Failed to follow system default: \(error)")
                        }
                    }
                }
            }
        }

        startServer()
    }

    private static func migrateV1Settings() {
        let defaults = UserDefaults.standard
        if let oldID = defaults.object(forKey: "outputDeviceID") as? Int, oldID != 0 {
            let deviceID = AudioDeviceID(oldID)
            if let uid = AudioDeviceManager.deviceUID(for: deviceID) {
                defaults.set(uid, forKey: "engineOutputDeviceUID")
                Log.output.info("Migrated v1 outputDeviceID \(oldID) → UID \(uid, privacy: .public)")
            }
            defaults.removeObject(forKey: "outputDeviceID")
        }
    }
}

extension AppState {
    func startServer() {
        let engine = self.engine
        let queue = self.queue
        let address = self.listenAddress
        let port = self.serverPort
        let authToken = self.authToken

        Task.detached {
            do {
                let app = try buildApplication(
                    engine: engine,
                    queue: queue,
                    appState: nil,
                    address: address,
                    port: port,
                    authToken: authToken
                )
                Log.server.info("Starting server on \(address, privacy: .public):\(port)")
                try await app.run()
            } catch {
                Log.server.error("Server failed: \(error)")
            }
        }
    }
}
```

- [ ] **Step 2: Rewrite SettingsView**

Replace `Sources/AirBridge/MenuBar/SettingsView.swift`:

```swift
import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @AppStorage("listenAddress") private var listenAddress: String = "127.0.0.1"
    @AppStorage("serverPort") private var portString: String = "9876"
    @AppStorage("authToken") private var authToken: String = ""
    @AppStorage("engineOutputDeviceUID") private var savedDeviceUID: String = ""
    @AppStorage("followSystemDefault") private var followSystemDefault: Bool = false

    @State private var outputDevices: [AudioOutputDeviceInfo] = []
    @State private var selectedDeviceUID: String = ""

    var body: some View {
        Form {
            Section("Audio Output") {
                Picker("Output Device", selection: $selectedDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(outputDevices) { device in
                        Text("\(device.name) (\(device.transport.rawValue))")
                            .tag(device.id)
                    }
                }
                .onChange(of: selectedDeviceUID) { _, newUID in
                    savedDeviceUID = newUID
                    if !newUID.isEmpty {
                        Task {
                            do {
                                _ = try await appState.engine.setOutputDevice(uid: newUID)
                                appState.currentOutputUID = newUID
                                appState.currentOutputName = outputDevices.first { $0.id == newUID }?.name ?? "Unknown"
                            } catch {
                                // Revert on failure
                                selectedDeviceUID = appState.currentOutputUID
                            }
                        }
                    }
                }

                Toggle("Follow system default", isOn: $followSystemDefault)
                    .help("Automatically re-pin engine when system default changes")

                HStack {
                    RoutePickerWrapper()
                        .frame(width: 30, height: 30)
                    Text("AirPlay / HomePod")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Refresh Devices") { refreshDevices() }

                Text("Use the AirPlay button to discover HomePods. They will then appear in the device list above.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Server") {
                HStack {
                    Text("Address")
                    TextField("Address", text: $listenAddress)
                        .frame(width: 200)
                }
                HStack {
                    Text("Port")
                    TextField("Port", text: $portString)
                        .frame(width: 80)
                }
            }

            Section("Authentication") {
                SecureField("Auth Token", text: $authToken)
                Text("Leave empty to disable authentication")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Server changes require app restart")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 420)
        .onAppear {
            refreshDevices()
            selectedDeviceUID = savedDeviceUID
        }
    }

    private func refreshDevices() {
        outputDevices = AudioDeviceManager.allOutputDevices(engineTargetUID: savedDeviceUID)
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/AirBridge/App/AppState.swift Sources/AirBridge/MenuBar/SettingsView.swift
git commit -m "feat: update AppState with queue, device observer, v1 migration; rewrite SettingsView for UIDs"
```

---

## Task 10: Update MenuBarView with Queue Display

**Files:**
- Create: `Sources/AirBridge/MenuBar/QueueListView.swift`
- Modify: `Sources/AirBridge/MenuBar/MenuBarView.swift`

- [ ] **Step 1: Create QueueListView**

Create `Sources/AirBridge/MenuBar/QueueListView.swift`:

```swift
import SwiftUI

struct QueueListView: View {
    let queueState: QueueState

    var body: some View {
        if queueState.tracks.isEmpty {
            Text("Queue empty")
                .foregroundColor(.secondary)
                .font(.caption)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(queueState.tracks.enumerated()), id: \.element.id) { idx, track in
                        HStack(spacing: 6) {
                            Text("\(idx + 1).")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(width: 20, alignment: .trailing)

                            statusIcon(for: idx)

                            Text(track.originalFilename)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
            .frame(maxHeight: 100)
        }
    }

    private func statusIcon(for index: Int) -> some View {
        Group {
            if let current = queueState.currentIndex {
                if index < current {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.secondary)
                } else if index == current {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                }
            } else {
                Image(systemName: "circle")
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption2)
    }
}
```

- [ ] **Step 2: Update MenuBarView**

Replace `Sources/AirBridge/MenuBar/MenuBarView.swift`:

```swift
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow

            // Current track
            if let file = appState.playbackState.currentFile {
                HStack {
                    Image(systemName: "music.note")
                    Text(file)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }

            Divider()

            // Queue
            QueueListView(queueState: appState.queueState)

            // Skip controls
            if appState.queueState.tracks.count > 1 {
                HStack {
                    Button(action: {
                        Task { _ = await appState.queue.previous() }
                    }) {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(.borderless)

                    Button(action: {
                        Task { _ = await appState.queue.next() }
                    }) {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            // Engine target
            HStack {
                Text("Playing through:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(appState.currentOutputName)
                    .font(.caption)
                    .bold()

                if appState.currentOutputUID != "" {
                    let defaultUID = AudioDeviceManager.deviceUID(for: AudioDeviceManager.getDefaultOutputDeviceID())
                    if appState.currentOutputUID != defaultUID {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .help("Engine target differs from system default")
                    }
                }
            }

            // Error
            if let error = appState.playbackState.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Divider()

            // Server info
            HStack {
                Image(systemName: "network")
                Text("\(appState.listenAddress):\(appState.serverPort)")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Button("Quit") {
                FileStaging.clearAll()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 260)
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(appState.playbackState.statusString.capitalized)
                .font(.headline)

            Spacer()

            if !appState.queueState.isEmpty {
                Text("\(appState.queueState.tracks.count) tracks")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch appState.playbackState {
        case .idle: return .green
        case .playing: return .blue
        case .paused: return .yellow
        case .error: return .red
        }
    }
}
```

- [ ] **Step 3: Build and run**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/AirBridge/MenuBar/QueueListView.swift Sources/AirBridge/MenuBar/MenuBarView.swift
git commit -m "feat: add QueueListView and update MenuBarView with queue display and engine target indicator"
```

---

## Task 11: Update AudioValidator for Data Validation

**Files:**
- Modify: `Sources/AirBridge/Playback/AudioValidator.swift`
- Modify: `Tests/AirBridgeTests/AudioValidatorTests.swift`

- [ ] **Step 1: Add data validation method**

In `Sources/AirBridge/Playback/AudioValidator.swift`, add after the existing `validate(path:)` method:

```swift
    static func validateExtension(_ filename: String) -> Result<String, AudioValidationError> {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            return .failure(.unsupportedFormat)
        }
        return .success(ext)
    }
```

- [ ] **Step 2: Add test**

In `Tests/AirBridgeTests/AudioValidatorTests.swift`, add:

```swift
    @Test func validateExtension_supported() {
        let result = AudioValidator.validateExtension("test.mp3")
        #expect(result == .success("mp3"))
    }

    @Test func validateExtension_unsupported() {
        let result = AudioValidator.validateExtension("test.ogg")
        #expect(result == .failure(.unsupportedFormat))
    }
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter AudioValidator`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/AirBridge/Playback/AudioValidator.swift Tests/AirBridgeTests/AudioValidatorTests.swift
git commit -m "feat: add extension-only validation to AudioValidator"
```

---

## Task 12: Wire AppState Queue State Updates and Cleanup on Quit

**Files:**
- Modify: `Sources/AirBridge/App/AppState.swift`
- Modify: `Sources/AirBridge/App/AirBridgeApp.swift`

- [ ] **Step 1: Add queue state sync to AppState**

In `Sources/AirBridge/App/AppState.swift`, inside `init()`, after the state callback setup, add a periodic queue state sync:

```swift
        // Periodic queue state sync
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let q = await queue.list()
                self.queueState = q
            }
        }
```

- [ ] **Step 2: Add cleanup on quit**

In `Sources/AirBridge/App/AirBridgeApp.swift`, the app already calls `FileStaging.clearAll()` via the Quit button in MenuBarView. No additional changes needed since the Quit button was updated in Task 10.

- [ ] **Step 3: Build and verify**

Run: `swift build`
Expected: Build succeeds.

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AirBridge/App/AppState.swift
git commit -m "feat: add periodic queue state sync to AppState"
```

---

## Task 13: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md to reflect v2 architecture**

Update the Architecture and Key Constraints sections of `CLAUDE.md` to reflect the v2 changes:

- Data flow now includes PlaybackQueue actor
- PlaybackEngine uses AVAudioEngine+AVAudioPlayerNode instead of AVPlayer
- API endpoints now include queue, multipart, and output device routes
- File uploads via multipart, staged to `~/.airbridge/queue/`
- UID-based device model

Update the manual testing commands:

```bash
# Upload and enqueue
curl -X POST http://127.0.0.1:9876/queue -F "file=@/path/to/test.mp3"

# Upload and play immediately
curl -X POST http://127.0.0.1:9876/play -F "file=@/path/to/test.mp3"

# Check status
curl http://127.0.0.1:9876/status

# Check queue
curl http://127.0.0.1:9876/queue

# Stop and clear
curl -X POST http://127.0.0.1:9876/stop

# List output devices
curl http://127.0.0.1:9876/outputs

# Set output device
curl -X PUT http://127.0.0.1:9876/outputs/current -H "Content-Type: application/json" -d '{"id":"DEVICE-UID"}'
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for v2 architecture"
```

---

## Task 14: Final Integration Test

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: All tests pass.

- [ ] **Step 2: Build release**

Run: `swift build -c release`
Expected: Build succeeds.

- [ ] **Step 3: Manual smoke test**

Run: `.build/debug/AirBridge`

Then in another terminal:
```bash
# Check status
curl http://127.0.0.1:9876/status

# Upload a file (use any mp3/wav you have)
curl -X POST http://127.0.0.1:9876/queue -F "file=@/path/to/test.mp3"

# Check queue
curl http://127.0.0.1:9876/queue

# List outputs
curl http://127.0.0.1:9876/outputs

# Stop
curl -X POST http://127.0.0.1:9876/stop
```

- [ ] **Step 4: Commit any final fixes**

If smoke testing reveals issues, fix and commit.

- [ ] **Step 5: Clean up spike directory**

```bash
rm -rf spike/
git add -A spike/
git commit -m "chore: remove engine spike after v2 implementation"
```
