# AirBridge — Design

## Overview

AirBridge is a macOS menu bar app that receives audio files via multipart HTTP upload, queues them, and plays them through a configurable output device. It serves as a relay bridge between OpenClaw (running on NixOS/Linux) and Apple HomePod or any other CoreAudio output.

**Core guarantees:**

- Audio plays on AirBridge's own pinned output device — system default is never modified
- Queue with full reorder, auto-advance, and multipart upload
- Output target controllable via API (list, get, set) with hot-swap during playback

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ AirBridge.app (single process, LSUIElement)                    │
│                                                                │
│  ┌──────────────┐        ┌────────────────────────────────┐    │
│  │ MenuBarShell │        │ HTTPTransport                  │    │
│  │  MenuBarExtra│        │  Hummingbird on 127.0.0.1:9876 │    │
│  └──────┬───────┘        └────────┬───────────────────────┘    │
│         │                         │                            │
│         │                         ▼                            │
│         │             ┌──────────────────────┐                 │
│         │             │ PlaybackQueue (actor)│                 │
│         │             │  ordered tracks      │                 │
│         │             │  currentIndex        │                 │
│         │             │  reorder, advance    │                 │
│         │             └──────────┬───────────┘                 │
│         │                        │                             │
│         ▼                        ▼                             │
│  ┌──────────────────────────────────────────────┐              │
│  │ AppState (@MainActor)                        │              │
│  │  @Published: playbackState, queueState,      │              │
│  │             currentOutputName                │              │
│  └──────────────────┬───────────────────────────┘              │
│                     │                                          │
│                     ▼                                          │
│  ┌──────────────────────────────────────────────┐              │
│  │ PlaybackEngine (actor)                       │              │
│  │  AVAudioEngine + AVAudioPlayerNode           │              │
│  │  pinned output via auAudioUnit               │              │
│  └──────────────────┬───────────────────────────┘              │
│                     │                                          │
│  ┌──────────────────▼───────────────────────────┐              │
│  │ AudioDeviceManager (read-only)               │              │
│  │  list, UID ↔ AudioDeviceID, observer         │              │
│  └──────────────────────────────────────────────┘              │
└────────────────────────────────────────────────────────────────┘
```

## Technology Choices

| Concern | Choice | Rationale |
|---|---|---|
| Language | Swift 5.10+ | Modern concurrency, `auAudioUnit` APIs |
| UI | SwiftUI MenuBarExtra | `.window` style, no AppKit needed for macOS 14+ |
| HTTP server | Hummingbird 2.x | Lightweight, async, minimal deps |
| Multipart parsing | MultipartKit | Works with Hummingbird; used in official multipart example |
| Audio playback | AVAudioEngine + AVAudioPlayerNode | Only public API with per-engine output device pinning |
| Device enumeration | CoreAudio directly | `AVAudioSession` doesn't exist on macOS |
| Route discovery | AVRoutePickerView | Public API to register HomePods with CoreAudio |
| Logging | os.Logger | Native, filterable in Console.app |
| Platform min | macOS 14 (Sonoma) | MenuBarExtra `.window` style, AUAudioUnit property APIs |

## Project Structure

```
AirBridge/
├── Package.swift
├── Sources/AirBridge/
│   ├── App/
│   │   ├── AirBridgeApp.swift          # @main, MenuBarExtra
│   │   └── AppState.swift              # ObservableObject, state bridge
│   ├── MenuBar/
│   │   ├── MenuBarView.swift           # popover content
│   │   ├── QueueListView.swift         # queue display
│   │   ├── RoutePickerWrapper.swift    # AVRoutePickerView bridge
│   │   └── SettingsView.swift          # device picker, server, auth
│   ├── Transport/
│   │   ├── HTTPServer.swift            # Hummingbird setup
│   │   ├── APIRoutes.swift             # endpoint handlers
│   │   └── MultipartParser.swift       # MultipartKit helpers
│   ├── Playback/
│   │   ├── PlaybackEngine.swift        # AVAudioEngine actor
│   │   ├── PlaybackQueue.swift         # queue actor
│   │   ├── PlaybackState.swift         # enums + DTOs
│   │   ├── AudioValidator.swift        # file + data validation
│   │   ├── AudioDeviceManager.swift    # CoreAudio read-only
│   │   └── OutputDeviceObserver.swift  # system default listener
│   └── Util/
│       ├── Logger.swift
│       └── FileStaging.swift           # ~/.airbridge/queue/ mgmt
├── Resources/Info.plist
└── Tests/AirBridgeTests/
```

## Output Device Model

### UID vs AudioDeviceID

- `AudioDeviceID` (`UInt32`) — reassigned every boot, internal use only
- Device UID (`String`, from `kAudioDevicePropertyDeviceUID`) — stable across reboots, API-facing

All persistence and API responses use UIDs. Conversion happens at the CoreAudio boundary.

```swift
struct AudioOutputDevice: Identifiable, Sendable {
        let id: String              // UID
            let coreAudioID: AudioDeviceID
                let name: String
                    let transport: Transport    // .builtIn | .usb | .bluetooth | .hdmi | .airplay | .virtual | .other
                        let isSystemDefault: Bool
                            let isEngineTarget: Bool
}
```

### Engine Target vs System Default

Two independent concepts:

- **Engine target** — what AirBridge plays through. Set via API or Settings. Persisted as UID.
- **System default** — macOS's global output. Changed by user tools (Sound prefs, `AVRoutePickerView`, etc.). AirBridge never writes to this.

`AVRoutePickerView` remains in the menu bar as a *discovery* affordance — picking a HomePod there makes it appear in CoreAudio's list, after which AirBridge can target it. The picker's write to system default is an Apple limitation we can't prevent.

### Hot-Swap Semantics

Changing engine target during playback:

1. Save `playerNode.currentTime` sample position
2. `playerNode.pause()`, `engine.pause()`
3. Set `kAudioOutputUnitProperty_CurrentDevice` on `engine.outputNode.auAudioUnit`
4. `engine.start()`, resume `playerNode.play()` at saved position

Expected gap: ~50–200 ms. Built-in devices are fast; AirPlay takes longer. If reconfiguration fails, engine transitions to `.error`.

## Data Model

```swift
enum PlaybackState: Sendable, Equatable {
        case idle
            case playing(trackID: UUID)
                case paused(trackID: UUID)
                    case error(message: String)
}

struct QueueTrack: Identifiable, Sendable, Equatable {
        let id: UUID
            let originalFilename: String
                let stagedPath: String           // ~/.airbridge/queue/<uuid>.<ext>
                    let addedAt: Date
                        let mimeType: String?
}

struct QueueState: Sendable {
        var tracks: [QueueTrack]
            var currentIndex: Int?           // nil = nothing playing
}
```

## Core Actors

### PlaybackEngine

Owns the audio graph. Single-track focused — queue awareness lives one level up.

```swift
actor PlaybackEngine {
        func setOutputDevice(uid: String) async throws -> Bool    // returns hot_swapped
            func play(track: QueueTrack) async throws
                func pause()
                    func resume()
                        func stop()
                            func setTrackFinishedCallback(_ cb: @escaping @Sendable () async -> Void)
}
```

Internals: `AVAudioEngine`, `AVAudioPlayerNode`, current `AVAudioFile`, current device UID.

### PlaybackQueue

Coordinates the queue, calls into `PlaybackEngine` for actual playback.

```swift
actor PlaybackQueue {
        func enqueue(track: QueueTrack) async -> (id: UUID, position: Int)
            func playNow(track: QueueTrack) async                  // insert at current+1, skip to it
                func remove(id: UUID) async -> Bool
                    func move(id: UUID, toPosition: Int) async throws
                        func clear() async                                     // stop + delete staged files
                            func next() async -> QueueTrack?
                                func previous() async -> QueueTrack?                   // restart at 0 if at position 0
                                    func list() async -> QueueState
}
```

On `engine.onTrackFinished`, queue advances `currentIndex`, plays the next track, or transitions to idle.

Removed tracks have their staged file deleted. On `clear()`, all staged files are removed.

### AppState

`@MainActor` `ObservableObject`. Bridges actor state to SwiftUI via `@Published`. Also owns HTTP server lifecycle.

```swift
@MainActor
final class AppState: ObservableObject {
        @Published var playbackState: PlaybackState
            @Published var queueState: QueueState
                @Published var currentOutputName: String
                    @Published var currentOutputUID: String
                        // ... server config, engine, queue refs
}
```

### AudioDeviceManager

Stateless read-only enum:

```swift
enum AudioDeviceManager {
        static func allOutputDevices() -> [AudioOutputDevice]
            static func getDefaultOutputDeviceID() -> AudioDeviceID
                static func deviceUID(for id: AudioDeviceID) -> String?
                    static func deviceID(forUID uid: String) -> AudioDeviceID?
                        static func transportType(for id: AudioDeviceID) -> UInt32
}
```

No `setDefaultOutputDevice` — deliberately absent.

### OutputDeviceObserver

Registers a CoreAudio property listener on `kAudioHardwarePropertyDefaultOutputDevice`. Fires callback to `AppState` so `/status` and `/outputs` reflect system changes without polling. If user enables `followSystemDefault`, also re-pins engine.

## File Staging

Uploads land in `~/.airbridge/queue/` with UUID filenames preserving the original extension.

- Size cap: 50 MB per upload (configurable); reject with 413 if exceeded
- Cleanup: file deleted when removed from queue, when track auto-advances past, or on `/stop`
- On app quit: entire staging dir wiped

```swift
enum FileStaging {
        static var directory: URL
            static func stage(data: Data, filename: String) throws -> (URL, UUID)
                static func remove(url: URL)
                    static func clearAll()
}
```

## API

All endpoints bind to `127.0.0.1:9876` by default. Auth middleware (Bearer token) applies when `authToken` is set.

### Playback Upload

#### POST /queue — enqueue track

Multipart form with `file` field (audio).

```bash
curl -X POST http://127.0.0.1:9876/queue -F "file=@reply-001.mp3"
```

```json
{ "id": "...", "filename": "reply-001.mp3", "position": 0, "queue_length": 1 }
```

If queue was idle, playback starts automatically.

#### POST /play — upload and play immediately

Same multipart format. Inserts at `currentIndex + 1`, advances to it. Queue remains intact.

```json
{ "id": "...", "filename": "urgent.mp3", "status": "playing", "queue_length": 4 }
```

### Queue Inspection & Control

#### GET /queue

```json
{
      "current_index": 1,
        "tracks": [
            { "id": "...", "filename": "a.mp3", "position": 0, "status": "played" },
                { "id": "...", "filename": "b.mp3", "position": 1, "status": "playing" },
                    { "id": "...", "filename": "c.mp3", "position": 2, "status": "queued" }
                      ]
}
```

Track `status` is derived from `position` vs `current_index`.

#### DELETE /queue/:id

Remove track. If it's the current track, advance to next. Staged file deleted.

```json
{ "removed": "...", "queue_length": 2 }
```

#### POST /queue/next, POST /queue/prev

Navigate forward/back. `prev` at position 0 restarts the current track.

```json
{ "status": "playing", "track": { "id": "...", "filename": "..." } }
```

#### POST /queue/move

```bash
curl -X POST .../queue/move -d '{"id": "...", "position": 0}'
```

Moves track to target index, shifts others, adjusts `currentIndex` so the playing track doesn't change.

### Transport Control

| Method | Path | Effect |
|---|---|---|
| POST | `/pause` | Pause current; queue preserved |
| POST | `/resume` | Resume paused |
| POST | `/stop` | Stop + clear queue + delete all staged files |

### Output Devices

#### GET /outputs

```json
{
      "current_engine_target": "BuiltInSpeakerDevice_UID",
        "current_system_default": "BuiltInSpeakerDevice_UID",
          "current_airplay_route": null,
            "devices": [
                {
                          "id": "BuiltInSpeakerDevice_UID",
                                "name": "MacBook Pro Speakers",
                                      "transport": "built_in",
                                            "is_system_default": true,
                                                  "is_engine_target": true
                                                      },
                                                          {
                                                                    "id": "AirPlay-HomePod-Kitchen-UID",
                                                                          "name": "HomePod Kitchen",
                                                                                "transport": "airplay",
                                                                                      "is_system_default": false,
                                                                                            "is_engine_target": false
                                                                                                }
                                                                                                  ]
}
```

`current_airplay_route` is populated only when the system default has `transport == "airplay"`. No `AVAudioSession` on macOS — derived from CoreAudio transport type.

Device list is re-queried live on each call. No caching, no streaming, no SSE.

#### GET /outputs/current

```json
{ "id": "...", "name": "HomePod Kitchen", "transport": "airplay" }
```

#### PUT /outputs/current

```bash
curl -X PUT .../outputs/current -d '{"id": "AirPlay-HomePod-Kitchen-UID"}'
```

```json
{ "id": "...", "name": "HomePod Kitchen", "transport": "airplay", "hot_swapped": true }
```

Errors:
- `404 device_not_found` — UID not in current device list
- `400 device_unavailable` — disconnected between lookup and setProperty call

### Status

#### GET /status

```json
{
      "status": "playing",
        "track": { "id": "...", "filename": "reply-002.mp3" },
          "queue_length": 3,
            "queue_position": 1,
              "output": {
                      "engine_target": "AirPlay-HomePod-Kitchen-UID",
                          "engine_target_name": "HomePod Kitchen",
                              "system_default": "BuiltInSpeakerDevice_UID",
                                  "airplay_route": "HomePod Kitchen"
                                    },
                                      "error": null
}
```

## State Flow

```
                    ┌──────────────────────────────────────┐
                                        │                                      │
                                          enqueue / play    ▼      auto-advance (queue non-empty)  │
                                            ──────▶  ┌──────────────┐  ──────────────▶  ┌────────┐   │
                                                       │ playing(n)   │                   │idle    │ ──┘
                                                                  └──────┬───────┘  ◀──────────────  └────────┘
                                                                                    │           queue exhausted
                                                                                              pause() │  resume()        or /stop
                                                                                                                ▼
                                                                                                                           ┌──────────────┐
                                                                                                                                      │ paused(n)    │
                                                                                                                                                 └──────────────┘

                                                                                                                                                   /stop from ANY state → idle + queue cleared + staged files deleted
                                                                                                                                                     error on play/decode → error state, surfaced in /status
                                                                                                                                                     ```

## Settings (UserDefaults)

| Key | Type | Purpose |
|---|---|---|
| `listenAddress` | String | HTTP bind address (default `127.0.0.1`) |
| `serverPort` | String | HTTP port (default `9876`) |
| `authToken` | String | Bearer token; empty disables auth |
| `engineOutputDeviceUID` | String | Pinned engine target UID |
| `followSystemDefault` | Bool | Re-pin engine on system default changes |
| `maxUploadBytes` | Int | Upload size cap, default 50 MB |

### Migration from V1

V1 stored `outputDeviceID: Int`. On launch, if present:
1. Look up the device's current UID
2. Write to `engineOutputDeviceUID`
3. Delete the old key

## Error Handling

| Scenario | Behavior |
|---|---|
| Invalid upload (format/empty) | 400, queue unchanged |
| Upload exceeds max size | 413, body discarded |
| Device UID not found | 404, engine unchanged |
| Device disappears mid-swap | 400 + engine enters `.error` |
| Engine decode error | `.error` state, next track does not auto-play |
| Disk full on staging | 507 (Insufficient Storage) |
| Server bind failure | Fatal log, menu bar shows error, retry on settings change |

## Logging

`os.Logger` with subsystem `com.gsmlg.airbridge`:

| Category | Scope |
|---|---|
| `http` | Requests, responses, auth failures |
| `playback` | Track starts, finishes, errors, state transitions |
| `queue` | Enqueue, remove, reorder, advance |
| `output` | Device changes, hot-swap timing, CoreAudio observer events |
| `server` | Bind, start, stop, crashes |

## Security

- HTTP binds to `127.0.0.1` by default; LAN binding requires explicit `listenAddress` change + auth token
- No private Apple APIs
- File access limited to the app's staging dir + app-reachable paths
- Auth via Bearer token

## Menu Bar UI

- Status row: colored dot + state
- Current track name
- Queue list (scrollable, up to ~5 visible), each row: position, filename, state icon
- Skip forward/back buttons (enabled when queue length > 1)
- "Playing through: `<engine_target_name>`" row
- Small ⓘ indicator when engine target ≠ system default
- `AVRoutePickerView` for AirPlay discovery
- Settings window: output device picker, server config, auth
- Quit

## Implementation Milestones

1. **M1: Engine rework.** Replace `AVPlayer` with `AVAudioEngine` + `AVAudioPlayerNode`. Pin output to saved UID. No writes to system default. Settings migration. UID-based `AudioDeviceManager`. Menu bar + Settings updated to UID.

2. **M2: Queue actor + auto-advance.** `PlaybackQueue`, `QueueTrack`, `QueueState`. Completion callback wiring. Tested via temporary path-based shim before M3.

3. **M3: Multipart upload.** Add `multipart-kit` dependency. `FileStaging`, `MultipartParser`. `POST /queue`, `POST /play` (multipart). Remove path-based `/play`.

4. **M4: Queue control.** `DELETE /queue/:id`, `POST /queue/next`, `/prev`, `/move`, `/pause`, `/resume`. `GET /queue`. Update `/stop` to clear queue.

5. **M5: Output device API.** `GET /outputs`, `/outputs/current`, `PUT /outputs/current`. Hot-swap logic. `OutputDeviceObserver` for system default changes. Extended `/status`.

6. **M6: UI polish.** `QueueListView`, engine target indicator, menu bar queue count, staging dir cleanup on quit.

## Linux-Side Usage

```bash
# Enqueue a reply
curl -X POST http://mac:9876/queue \
  -F "file=@/tmp/openclaw/reply-001.mp3"

# Play something urgent, cutting the line
curl -X POST http://mac:9876/play \
  -F "file=@/tmp/openclaw/urgent.mp3"

# Check queue
curl http://mac:9876/queue

# Switch output to HomePod (UID learned once, then cached)
curl -X PUT http://mac:9876/outputs/current \
  -d '{"id":"AirPlay-HomePod-Kitchen-UID"}'

# Skip
curl -X POST http://mac:9876/queue/next
```

No scp step needed — upload is direct.

## Limitations

- AirPlay device selection still requires user to pick via `AVRoutePickerView` first (to register with CoreAudio); AirBridge then targets it via API
- Hot-swap has a brief (~50–200 ms) audio gap
- Single playback stream — no mixing, no concurrent tracks
- Large files (>50 MB) intentionally unsupported; AirBridge is for short replies/chimes, not music streaming
- No auth beyond static Bearer token (mTLS / OAuth are non-goals)

