# AirBridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar app that receives audio files via local HTTP API and plays them through system audio output (targeting HomePod via AirPlay).

**Architecture:** Single-process menu bar app using SwiftUI `MenuBarExtra`. A `PlaybackEngine` Swift actor manages AVAudioPlayer state. Hummingbird 2.x HTTP server on 127.0.0.1:9876 accepts play/stop/status commands. `AppState` ObservableObject bridges engine state to the SwiftUI menu bar UI.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit bridge, Hummingbird 2.x, AVAudioPlayer, AVRoutePickerView, SPM

---

## File Structure

```
AirBridge/
├── Package.swift                          # SPM manifest with Hummingbird dep
├── Sources/
│   └── AirBridge/
│       ├── App/
│       │   ├── AirBridgeApp.swift         # @main, SwiftUI App with MenuBarExtra
│       │   └── AppState.swift             # ObservableObject, shared state
│       ├── MenuBar/
│       │   ├── MenuBarView.swift          # Popover content (status, controls)
│       │   ├── RoutePickerWrapper.swift   # NSViewRepresentable for AVRoutePickerView
│       │   └── SettingsView.swift         # Port config, auto-cleanup toggle
│       ├── Transport/
│       │   ├── HTTPServer.swift           # Hummingbird Application setup
│       │   └── APIRoutes.swift            # Route handlers for /play, /stop, /status
│       ├── Playback/
│       │   ├── PlaybackEngine.swift       # Actor: AVAudioPlayer + state machine
│       │   ├── PlaybackState.swift        # State enum + API response models
│       │   └── AudioValidator.swift       # File validation before playback
│       └── Util/
│           └── Logger.swift               # os.Logger category wrappers
├── Resources/
│   └── Info.plist                         # LSUIElement=true
└── Tests/
    └── AirBridgeTests/
        ├── AudioValidatorTests.swift
        ├── PlaybackStateTests.swift
        └── APIRoutesTests.swift
```

---

### Task 1: Package.swift and Project Skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/AirBridge/App/AirBridgeApp.swift` (stub)

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AirBridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AirBridge",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/AirBridge"
        ),
        .testTarget(
            name: "AirBridgeTests",
            dependencies: ["AirBridge"],
            path: "Tests/AirBridgeTests"
        ),
    ]
)
```

- [ ] **Step 2: Create minimal app entry point**

Create `Sources/AirBridge/App/AirBridgeApp.swift`:

```swift
import SwiftUI

@main
struct AirBridgeApp: App {
    var body: some Scene {
        MenuBarExtra("AirBridge", systemImage: "airplayaudio") {
            Text("AirBridge is running")
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
```

- [ ] **Step 3: Build to verify project compiles**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/
git commit -m "feat: scaffold SPM project with SwiftUI MenuBarExtra entry point"
```

---

### Task 2: Logging Utilities

**Files:**
- Create: `Sources/AirBridge/Util/Logger.swift`

- [ ] **Step 1: Create Logger.swift**

```swift
import OSLog

enum Log {
    static let http = Logger(subsystem: "com.gsmlg.airbridge", category: "http")
    static let playback = Logger(subsystem: "com.gsmlg.airbridge", category: "playback")
    static let server = Logger(subsystem: "com.gsmlg.airbridge", category: "server")
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/AirBridge/Util/Logger.swift
git commit -m "feat: add os.Logger wrappers for http, playback, server categories"
```

---

### Task 3: PlaybackState and API Response Models

**Files:**
- Create: `Sources/AirBridge/Playback/PlaybackState.swift`
- Create: `Tests/AirBridgeTests/PlaybackStateTests.swift`

- [ ] **Step 1: Write tests for PlaybackState**

Create `Tests/AirBridgeTests/PlaybackStateTests.swift`:

```swift
import Testing
@testable import AirBridge

@Test func idleState_isNotPlaying() {
    let state = PlaybackState.idle
    #expect(state.isPlaying == false)
}

@Test func playingState_isPlaying() {
    let state = PlaybackState.playing(file: "/tmp/test.mp3")
    #expect(state.isPlaying == true)
}

@Test func statusResponse_fromIdleState() {
    let response = StatusResponse(state: .idle, route: nil)
    #expect(response.status == "idle")
    #expect(response.file == nil)
    #expect(response.error == nil)
}

@Test func statusResponse_fromPlayingState() {
    let response = StatusResponse(state: .playing(file: "/tmp/test.mp3"), route: "HomePod Kitchen")
    #expect(response.status == "playing")
    #expect(response.file == "/tmp/test.mp3")
    #expect(response.route == "HomePod Kitchen")
}

@Test func statusResponse_fromErrorState() {
    let response = StatusResponse(state: .error(message: "decode failed"), route: nil)
    #expect(response.status == "error")
    #expect(response.error == "decode failed")
}

@Test func playRequest_decodesFromJSON() throws {
    let json = #"{"path":"/tmp/reply.mp3"}"#
    let data = json.data(using: .utf8)!
    let request = try JSONDecoder().decode(PlayRequest.self, from: data)
    #expect(request.path == "/tmp/reply.mp3")
}

@Test func statusResponse_encodesToJSON() throws {
    let response = StatusResponse(state: .playing(file: "/tmp/test.mp3"), route: nil)
    let data = try JSONEncoder().encode(response)
    let json = String(data: data, encoding: .utf8)!
    #expect(json.contains("\"status\":\"playing\""))
    #expect(json.contains("\"file\":\"/tmp/test.mp3\""))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PlaybackState`
Expected: FAIL — types not defined

- [ ] **Step 3: Implement PlaybackState.swift**

Create `Sources/AirBridge/Playback/PlaybackState.swift`:

```swift
import Foundation

enum PlaybackState: Sendable, Equatable {
    case idle
    case playing(file: String)
    case paused(file: String)
    case error(message: String)

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    var statusString: String {
        switch self {
        case .idle: "idle"
        case .playing: "playing"
        case .paused: "paused"
        case .error: "error"
        }
    }

    var currentFile: String? {
        switch self {
        case .playing(let file), .paused(let file): file
        default: nil
        }
    }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

struct PlayRequest: Decodable, Sendable {
    let path: String
}

struct PlayResponse: Codable, Sendable {
    let status: String
    let file: String
}

struct StopResponse: Codable, Sendable {
    let status: String
}

struct ErrorResponse: Codable, Sendable {
    let error: String
    let message: String
}

struct StatusResponse: Codable, Sendable {
    let status: String
    let file: String?
    let route: String?
    let error: String?

    init(state: PlaybackState, route: String?) {
        self.status = state.statusString
        self.file = state.currentFile
        self.route = route
        self.error = state.errorMessage
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PlaybackState`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AirBridge/Playback/PlaybackState.swift Tests/AirBridgeTests/PlaybackStateTests.swift
git commit -m "feat: add PlaybackState enum and API request/response models"
```

---

### Task 4: AudioValidator

**Files:**
- Create: `Sources/AirBridge/Playback/AudioValidator.swift`
- Create: `Tests/AirBridgeTests/AudioValidatorTests.swift`

- [ ] **Step 1: Write tests for AudioValidator**

Create `Tests/AirBridgeTests/AudioValidatorTests.swift`:

```swift
import Testing
import Foundation
@testable import AirBridge

@Test func validate_fileNotFound_returnsError() throws {
    let result = AudioValidator.validate(path: "/nonexistent/file.mp3")
    #expect(result == .failure(.fileNotFound))
}

@Test func validate_unsupportedFormat_returnsError() throws {
    let tmpDir = FileManager.default.temporaryDirectory
    let file = tmpDir.appendingPathComponent("test.ogg")
    try Data([0x01]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = AudioValidator.validate(path: file.path)
    #expect(result == .failure(.unsupportedFormat))
}

@Test func validate_emptyFile_returnsError() throws {
    let tmpDir = FileManager.default.temporaryDirectory
    let file = tmpDir.appendingPathComponent("empty.mp3")
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = AudioValidator.validate(path: file.path)
    #expect(result == .failure(.emptyFile))
}

@Test func validate_validMp3_returnsSuccess() throws {
    let tmpDir = FileManager.default.temporaryDirectory
    let file = tmpDir.appendingPathComponent("valid.mp3")
    try Data([0xFF, 0xFB, 0x90, 0x00]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    let result = AudioValidator.validate(path: file.path)
    #expect(result == .success(file.path))
}

@Test func validate_supportedExtensions() {
    let supported = AudioValidator.supportedExtensions
    #expect(supported.contains("mp3"))
    #expect(supported.contains("wav"))
    #expect(supported.contains("m4a"))
    #expect(supported.contains("aiff"))
}

@Test func validationError_descriptions() {
    #expect(AudioValidationError.fileNotFound.errorDescription != nil)
    #expect(AudioValidationError.notReadable.errorDescription != nil)
    #expect(AudioValidationError.unsupportedFormat.errorDescription != nil)
    #expect(AudioValidationError.emptyFile.errorDescription != nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AudioValidator`
Expected: FAIL — types not defined

- [ ] **Step 3: Implement AudioValidator.swift**

Create `Sources/AirBridge/Playback/AudioValidator.swift`:

```swift
import Foundation

enum AudioValidationError: Error, Equatable, Sendable {
    case fileNotFound
    case notReadable
    case unsupportedFormat
    case emptyFile

    var errorDescription: String {
        switch self {
        case .fileNotFound: "File does not exist at path"
        case .notReadable: "File is not readable"
        case .unsupportedFormat: "Unsupported audio format"
        case .emptyFile: "File is empty"
        }
    }

    var errorCode: String {
        switch self {
        case .fileNotFound: "file_not_found"
        case .notReadable: "not_readable"
        case .unsupportedFormat: "unsupported_format"
        case .emptyFile: "empty_file"
        }
    }
}

enum AudioValidator {
    static let supportedExtensions: Set<String> = ["mp3", "wav", "m4a", "aiff"]

    static func validate(path: String) -> Result<String, AudioValidationError> {
        let fm = FileManager.default

        guard fm.fileExists(atPath: path) else {
            return .failure(.fileNotFound)
        }

        guard fm.isReadableFile(atPath: path) else {
            return .failure(.notReadable)
        }

        let ext = (path as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            return .failure(.unsupportedFormat)
        }

        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64,
              size > 0 else {
            return .failure(.emptyFile)
        }

        return .success(path)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AudioValidator`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AirBridge/Playback/AudioValidator.swift Tests/AirBridgeTests/AudioValidatorTests.swift
git commit -m "feat: add AudioValidator with file existence, format, and size checks"
```

---

### Task 5: PlaybackEngine Actor

**Files:**
- Create: `Sources/AirBridge/Playback/PlaybackEngine.swift`

- [ ] **Step 1: Implement PlaybackEngine**

Create `Sources/AirBridge/Playback/PlaybackEngine.swift`:

```swift
import AVFoundation
import Foundation

actor PlaybackEngine: NSObject, AVAudioPlayerDelegate {
    private(set) var state: PlaybackState = .idle
    private var player: AVAudioPlayer?
    private var stateCallback: (@Sendable (PlaybackState) -> Void)?

    func setStateCallback(_ callback: @escaping @Sendable (PlaybackState) -> Void) {
        self.stateCallback = callback
    }

    func play(path: String) throws -> PlaybackState {
        switch AudioValidator.validate(path: path) {
        case .failure(let error):
            throw error
        case .success:
            break
        }

        player?.stop()
        player = nil

        let url = URL(fileURLWithPath: path)
        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.delegate = self
        newPlayer.play()
        player = newPlayer

        Log.playback.info("Playing: \(path)")
        transition(to: .playing(file: path))
        return state
    }

    func stop() -> PlaybackState {
        player?.stop()
        player = nil
        Log.playback.info("Stopped playback")
        transition(to: .idle)
        return state
    }

    func pause() -> PlaybackState {
        guard case .playing(let file) = state else { return state }
        player?.pause()
        Log.playback.info("Paused: \(file)")
        transition(to: .paused(file: file))
        return state
    }

    func resume() -> PlaybackState {
        guard case .paused(let file) = state else { return state }
        player?.play()
        Log.playback.info("Resumed: \(file)")
        transition(to: .playing(file: file))
        return state
    }

    private func transition(to newState: PlaybackState) {
        state = newState
        let cb = stateCallback
        let s = newState
        Task { @MainActor in
            cb?(s)
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Log.playback.info("Playback finished (success: \(flag))")
        Task { await self.transition(to: .idle) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let msg = error?.localizedDescription ?? "Unknown decode error"
        Log.playback.error("Decode error: \(msg)")
        Task { await self.transition(to: .error(message: msg)) }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/AirBridge/Playback/PlaybackEngine.swift
git commit -m "feat: add PlaybackEngine actor with AVAudioPlayer state machine"
```

---

### Task 6: AppState Observable Object

**Files:**
- Create: `Sources/AirBridge/App/AppState.swift`

- [ ] **Step 1: Implement AppState**

Create `Sources/AirBridge/App/AppState.swift`:

```swift
import SwiftUI
import AVFoundation

@MainActor
final class AppState: ObservableObject {
    @Published var playbackState: PlaybackState = .idle
    @Published var currentRoute: String = "System Default"
    @Published var serverPort: Int = 9876

    let engine = PlaybackEngine()

    init() {
        Task {
            await engine.setStateCallback { [weak self] newState in
                Task { @MainActor in
                    self?.playbackState = newState
                }
            }
        }
        observeRoute()
    }

    private func observeRoute() {
        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.updateRouteName()
            }
        }
        updateRouteName()
    }

    private func updateRouteName() {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        currentRoute = output?.portName ?? "System Default"
    }

    func play(path: String) async throws {
        _ = try await engine.play(path: path)
    }

    func stop() async {
        _ = await engine.stop()
    }
}
```

Note: `AVAudioSession` is available on macOS 11+ but route observation may be limited. If `AVAudioSession` is unavailable, the route display will show "System Default" as fallback.

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED. If `AVAudioSession` is not available on macOS for route observation, we'll adapt in the next step.

- [ ] **Step 3: Handle macOS AVAudioSession availability**

If the build fails because `AVAudioSession` is not available on macOS, replace the route observation with a simpler approach:

```swift
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var playbackState: PlaybackState = .idle
    @Published var currentRoute: String = "System Default"
    @Published var serverPort: Int = 9876

    let engine = PlaybackEngine()

    init() {
        Task {
            await engine.setStateCallback { [weak self] newState in
                Task { @MainActor in
                    self?.playbackState = newState
                }
            }
        }
    }

    func play(path: String) async throws {
        _ = try await engine.play(path: path)
    }

    func stop() async {
        _ = await engine.stop()
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/AirBridge/App/AppState.swift
git commit -m "feat: add AppState observable bridging PlaybackEngine to SwiftUI"
```

---

### Task 7: HTTP Server and API Routes

**Files:**
- Create: `Sources/AirBridge/Transport/HTTPServer.swift`
- Create: `Sources/AirBridge/Transport/APIRoutes.swift`
- Create: `Tests/AirBridgeTests/APIRoutesTests.swift`

- [ ] **Step 1: Write API route tests**

Create `Tests/AirBridgeTests/APIRoutesTests.swift`:

```swift
import Testing
import Hummingbird
import HummingbirdTesting
@testable import AirBridge
import Foundation

@Test func statusEndpoint_returnsIdleByDefault() async throws {
    let engine = PlaybackEngine()
    let app = try buildTestApplication(engine: engine)

    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/status", method: .get)
        #expect(response.status == .ok)
        let body = try JSONDecoder().decode(StatusResponse.self, from: response.body)
        #expect(body.status == "idle")
    }
}

@Test func playEndpoint_withInvalidPath_returns400() async throws {
    let engine = PlaybackEngine()
    let app = try buildTestApplication(engine: engine)

    try await app.test(.router) { client in
        let requestBody = try JSONEncoder().encode(PlayRequest(path: "/nonexistent/file.mp3"))
        var buffer = ByteBuffer()
        buffer.writeBytes(requestBody)
        let response = try await client.execute(
            uri: "/play",
            method: .post,
            headers: [.contentType: "application/json"],
            body: buffer
        )
        #expect(response.status == .badRequest)
    }
}

@Test func stopEndpoint_returnsIdle() async throws {
    let engine = PlaybackEngine()
    let app = try buildTestApplication(engine: engine)

    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/stop", method: .post)
        #expect(response.status == .ok)
        let body = try JSONDecoder().decode(StopResponse.self, from: response.body)
        #expect(body.status == "idle")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter APIRoutes`
Expected: FAIL — `buildTestApplication` and routes not defined

- [ ] **Step 3: Implement APIRoutes.swift**

Create `Sources/AirBridge/Transport/APIRoutes.swift`:

```swift
import Foundation
import Hummingbird

func buildRouter(engine: PlaybackEngine, appState: AppState?) -> Router<BasicRequestContext> {
    let router = Router(context: BasicRequestContext.self)

    router.get("/status") { _, _ -> StatusResponse in
        let state = await engine.state
        let route = await appState?.currentRoute
        return StatusResponse(state: state, route: route)
    }

    router.post("/play") { request, context -> Response in
        let playRequest: PlayRequest
        do {
            playRequest = try await request.decode(as: PlayRequest.self, context: context)
        } catch {
            let errorResponse = ErrorResponse(error: "invalid_request", message: "Invalid JSON body")
            let data = try JSONEncoder().encode(errorResponse)
            return Response(
                status: .badRequest,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        do {
            let state = try await engine.play(path: playRequest.path)
            let playResponse = PlayResponse(status: state.statusString, file: playRequest.path)
            let data = try JSONEncoder().encode(playResponse)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        } catch let error as AudioValidationError {
            let errorResponse = ErrorResponse(error: error.errorCode, message: error.errorDescription)
            let data = try JSONEncoder().encode(errorResponse)
            return Response(
                status: .badRequest,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }
    }

    router.post("/stop") { _, _ -> StopResponse in
        _ = await engine.stop()
        return StopResponse(status: "idle")
    }

    return router
}

func buildTestApplication(engine: PlaybackEngine) throws -> some ApplicationProtocol {
    let router = buildRouter(engine: engine, appState: nil)
    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: 0))
    )
}
```

- [ ] **Step 4: Implement HTTPServer.swift**

Create `Sources/AirBridge/Transport/HTTPServer.swift`:

```swift
import Hummingbird

func buildApplication(engine: PlaybackEngine, appState: AppState?, port: Int) throws -> some ApplicationProtocol {
    let router = buildRouter(engine: engine, appState: appState)

    let app = Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: port))
    )

    Log.server.info("Server configured on 127.0.0.1:\(port)")
    return app
}
```

- [ ] **Step 5: Add HummingbirdTesting dependency to Package.swift**

Update `Package.swift` test target to include HummingbirdTesting:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AirBridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "AirBridge",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
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

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter APIRoutes`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add Sources/AirBridge/Transport/ Tests/AirBridgeTests/APIRoutesTests.swift Package.swift
git commit -m "feat: add Hummingbird HTTP server with /play, /stop, /status routes"
```

---

### Task 8: MenuBarView

**Files:**
- Create: `Sources/AirBridge/MenuBar/MenuBarView.swift`

- [ ] **Step 1: Implement MenuBarView**

Create `Sources/AirBridge/MenuBar/MenuBarView.swift`:

```swift
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow
            Divider()

            if let file = appState.playbackState.currentFile {
                Label(URL(fileURLWithPath: file).lastPathComponent, systemImage: "music.note")
                    .font(.caption)
                    .lineLimit(1)
            }

            if appState.playbackState.isPlaying {
                Button("Stop") {
                    Task { await appState.stop() }
                }
            }

            if case .error(let msg) = appState.playbackState {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()
            Label("Route: \(appState.currentRoute)", systemImage: "airplayaudio")
                .font(.caption)
            Label("Listening on 127.0.0.1:\(appState.serverPort)", systemImage: "network")
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 240)
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text("AirBridge — \(appState.playbackState.statusString)")
                .font(.headline)
        }
    }

    private var statusColor: Color {
        switch appState.playbackState {
        case .idle: .green
        case .playing: .blue
        case .paused: .yellow
        case .error: .red
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/AirBridge/MenuBar/MenuBarView.swift
git commit -m "feat: add MenuBarView with status indicator, controls, and server info"
```

---

### Task 9: RoutePickerWrapper

**Files:**
- Create: `Sources/AirBridge/MenuBar/RoutePickerWrapper.swift`

- [ ] **Step 1: Implement RoutePickerWrapper**

Create `Sources/AirBridge/MenuBar/RoutePickerWrapper.swift`:

```swift
import SwiftUI
import AVKit

struct RoutePickerWrapper: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/AirBridge/MenuBar/RoutePickerWrapper.swift
git commit -m "feat: add AVRoutePickerView NSViewRepresentable wrapper"
```

---

### Task 10: SettingsView

**Files:**
- Create: `Sources/AirBridge/MenuBar/SettingsView.swift`

- [ ] **Step 1: Implement SettingsView**

Create `Sources/AirBridge/MenuBar/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @AppStorage("serverPort") private var portString: String = "9876"

    var body: some View {
        Form {
            Section("Server") {
                TextField("Port", text: $portString)
                    .frame(width: 80)
                Text("Requires app restart to take effect")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 300, height: 150)
        .padding()
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/AirBridge/MenuBar/SettingsView.swift
git commit -m "feat: add SettingsView with port configuration"
```

---

### Task 11: Wire Up AirBridgeApp with Server Lifecycle

**Files:**
- Modify: `Sources/AirBridge/App/AirBridgeApp.swift`

- [ ] **Step 1: Update AirBridgeApp to start server and show MenuBarView**

Replace `Sources/AirBridge/App/AirBridgeApp.swift`:

```swift
import SwiftUI

@main
struct AirBridgeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("AirBridge", systemImage: "airplayaudio") {
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
        }
    }

    init() {
        startServer()
    }

    private func startServer() {
        Task {
            do {
                let state = AppState()
                let port = state.serverPort
                let app = try buildApplication(engine: state.engine, appState: state, port: port)
                Log.server.info("Starting server on 127.0.0.1:\(port)")
                try await app.runService()
            } catch {
                Log.server.error("Server failed to start: \(error)")
            }
        }
    }
}
```

Note: The server lifecycle is tied to the app — it runs until the app quits. There's a subtlety here: `init()` creates a separate `AppState` from `@StateObject`. We need to fix this so they share the same instance.

Corrected approach — use a shared instance pattern:

```swift
import SwiftUI

@main
struct AirBridgeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("AirBridge", systemImage: "airplayaudio") {
            MenuBarView(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
        }
    }
}

// Extension on AppState to manage server lifecycle
extension AppState {
    func startServer() {
        Task.detached { [weak self] in
            guard let self else { return }
            let port = await self.serverPort
            let engine = await self.engine
            do {
                let app = try buildApplication(engine: engine, appState: self, port: port)
                Log.server.info("Starting server on 127.0.0.1:\(port)")
                try await app.runService()
            } catch {
                Log.server.error("Server failed to start: \(error)")
            }
        }
    }
}
```

Then in `AppState.init()`, add `startServer()` call:

Update `Sources/AirBridge/App/AppState.swift` — add to end of `init()`:

```swift
startServer()
```

- [ ] **Step 2: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/AirBridge/App/AirBridgeApp.swift Sources/AirBridge/App/AppState.swift
git commit -m "feat: wire MenuBarExtra, SettingsView, and HTTP server lifecycle"
```

---

### Task 12: Info.plist

**Files:**
- Create: `Resources/Info.plist`

- [ ] **Step 1: Create Info.plist**

Create `Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AirBridge</string>
    <key>CFBundleIdentifier</key>
    <string>com.gsmlg.airbridge</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>AirBridge needs audio session access for AirPlay routing.</string>
</dict>
</plist>
```

- [ ] **Step 2: Update Package.swift to include resources**

The executable target needs the resources path. Update the executable target in `Package.swift`:

```swift
.executableTarget(
    name: "AirBridge",
    dependencies: [
        .product(name: "Hummingbird", package: "hummingbird"),
    ],
    path: "Sources/AirBridge",
    resources: [
        .copy("../../Resources/Info.plist"),
    ]
),
```

Note: SPM resource paths are relative to the target's source directory. If this doesn't resolve correctly, move `Info.plist` into `Sources/AirBridge/Resources/Info.plist` and use `.copy("Resources/Info.plist")`.

- [ ] **Step 3: Build to verify**

Run: `swift build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Resources/Info.plist Package.swift
git commit -m "feat: add Info.plist with LSUIElement for menu bar-only mode"
```

---

### Task 13: CLAUDE.md Project Instructions

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: Create CLAUDE.md**

```markdown
# AirBridge

macOS menu bar audio relay app. Receives audio files via local HTTP API, plays through system output (targeting HomePod via AirPlay).

## Stack
- Swift 5.9+, SwiftUI, AppKit bridge
- Hummingbird 2.x for HTTP server
- AVAudioPlayer for playback
- AVRoutePickerView for AirPlay selection

## Architecture
- Single-process menu bar app (LSUIElement)
- PlaybackEngine is a Swift actor — all playback state flows through it
- HTTPServer routes call PlaybackEngine methods
- MenuBarView observes AppState which mirrors PlaybackEngine state

## Key constraints
- Bind HTTP only to 127.0.0.1
- No private Apple APIs
- AVRoutePickerView is user-initiated only — cannot programmatically select HomePod
- Replacement policy: new play request stops current playback immediately
- Supported formats: mp3, wav, m4a, aiff

## Build
swift build

## Test
swift test

## Manual test
curl -X POST http://127.0.0.1:9876/play -H "Content-Type: application/json" -d '{"path":"/path/to/test.mp3"}'
curl http://127.0.0.1:9876/status
curl -X POST http://127.0.0.1:9876/stop
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add CLAUDE.md with project instructions"
```

---

### Task 14: Integration Test — Full Flow

**Files:**
- No new files — uses existing test infrastructure

- [ ] **Step 1: Run all tests**

Run: `swift test`
Expected: All tests PASS

- [ ] **Step 2: Build release**

Run: `swift build -c release`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Manual smoke test**

Run the app: `.build/release/AirBridge`

In another terminal:
```bash
# Check status
curl -s http://127.0.0.1:9876/status | python3 -m json.tool

# Try playing a non-existent file (should return 400)
curl -s -X POST http://127.0.0.1:9876/play \
  -H "Content-Type: application/json" \
  -d '{"path":"/tmp/nonexistent.mp3"}' | python3 -m json.tool

# Stop
curl -s -X POST http://127.0.0.1:9876/stop | python3 -m json.tool
```

Expected: status returns idle, play returns 400 with file_not_found error, stop returns idle.

- [ ] **Step 4: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: address issues found during integration testing"
```
