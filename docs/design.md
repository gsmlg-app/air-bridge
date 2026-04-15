# AirBridge — macOS Menu Bar Audio Relay

## Overview

AirBridge is a lightweight macOS menu bar app that receives audio files via a local HTTP API and plays them through the system audio output, enabling HomePod playback when selected as the AirPlay target. It serves as a relay bridge between OpenClaw (running on NixOS/Linux) and Apple HomePod.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  AirBridge.app (single process)                 │
│                                                 │
│  ┌──────────────┐   ┌───────────────────────┐   │
│  │ MenuBarShell │   │ HTTPTransport         │   │
│  │  NSStatusItem│   │  Hummingbird on       │   │
│  │  popover/menu│   │  127.0.0.1:9876       │   │
│  └──────┬───────┘   └──────────┬────────────┘   │
│         │                      │                 │
│         ▼                      ▼                 │
│  ┌──────────────────────────────────────────┐   │
│  │ PlaybackEngine (actor)                   │   │
│  │  AVAudioPlayer + state machine           │   │
│  │  states: idle | playing | paused | error │   │
│  └──────────────────┬───────────────────────┘   │
│                     │                            │
│  ┌──────────────────▼───────────────────────┐   │
│  │ RouteManager                             │   │
│  │  AVRoutePickerView (user-initiated)      │   │
│  │  current route observation               │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

## Technology Choices

| Concern | Choice | Rationale |
|---|---|---|
| Language | Swift 5.9+ | Required for macOS APIs, modern concurrency |
| UI | SwiftUI + AppKit bridge | SwiftUI for popover content, AppKit for NSStatusItem |
| HTTP server | Hummingbird 2.x | Lightweight async server, minimal footprint, no Vapor overhead |
| Audio playback | AVAudioPlayer | Simpler than AVPlayer for local file playback; delegate-based completion; handles mp3/wav/m4a/aiff natively |
| Route selection | AVRoutePickerView via NSViewRepresentable | Only public API for AirPlay device picker; user-initiated selection |
| Logging | os.Logger | System-native, lightweight, filterable via Console.app |
| Package manager | Swift Package Manager | Standard, no CocoaPods/Carthage needed |

## App Lifecycle Model

- `Info.plist`: set `LSUIElement = true` (no Dock icon, no main menu bar)
- `NSApplicationActivationPolicy.accessory` — menu bar-only presence
- No main window; optional settings window on demand
- `NSStatusItem` with a speaker/bridge icon in the menu bar

## Project Structure

```
AirBridge/
├── Package.swift
├── Sources/
│   └── AirBridge/
│       ├── App/
│       │   ├── AirBridgeApp.swift          # @main, SwiftUI App with MenuBarExtra
│       │   └── AppState.swift              # ObservableObject, shared app state
│       ├── MenuBar/
│       │   ├── MenuBarView.swift           # Menu bar popover content
│       │   ├── RoutePickerWrapper.swift    # NSViewRepresentable for AVRoutePickerView
│       │   └── SettingsView.swift          # Compact settings panel
│       ├── Transport/
│       │   ├── HTTPServer.swift            # Hummingbird server setup, route registration
│       │   └── APIRoutes.swift             # Handler functions for each endpoint
│       ├── Playback/
│       │   ├── PlaybackEngine.swift        # Actor wrapping AVAudioPlayer + state
│       │   ├── PlaybackState.swift         # State enum + status model
│       │   └── AudioValidator.swift        # File existence, readability, format checks
│       └── Util/
│           └── Logger.swift                # os.Logger category wrappers
├── Resources/
│   └── Info.plist
├── README.md
└── CLAUDE.md                               # Claude Code project instructions
```

## API Design

All endpoints bind to `127.0.0.1:9876` (port configurable).

### POST /play

Request:
```json
{
  "path": "/tmp/openclaw/reply-123.mp3"
}
```

Response `200`:
```json
{
  "status": "playing",
  "file": "/tmp/openclaw/reply-123.mp3"
}
```

Response `400`:
```json
{
  "error": "file_not_found",
  "message": "File does not exist at path"
}
```

Behavior: if already playing, stop current playback immediately and start the new file (replacement policy).

### POST /stop

Request: empty body.

Response `200`:
```json
{
  "status": "idle"
}
```

### GET /status

Response `200`:
```json
{
  "status": "playing",
  "file": "/tmp/openclaw/reply-123.mp3",
  "route": "HomePod Kitchen",
  "error": null
}
```

Status values: `idle`, `playing`, `paused`, `error`.

### Optional Endpoints (v1 stretch)

- `POST /pause` — pause current playback
- `POST /resume` — resume paused playback
- `POST /volume` — `{ "level": 0.8 }` (0.0–1.0)
- `GET /devices` — list available AirPlay routes (if observable via public API)

## Core Components

### PlaybackEngine (actor)

```
@Observable actor PlaybackEngine {
    state: PlaybackState          // .idle | .playing(file) | .paused(file) | .error(msg)
    private player: AVAudioPlayer?

    func play(path: String) async throws -> PlaybackState
    func stop() -> PlaybackState
    func pause() -> PlaybackState
    func resume() -> PlaybackState
    var currentStatus: StatusResponse { get }
}
```

Key behaviors:
- Validate file via `AudioValidator` before attempting playback
- On `play()`: stop any current playback, create new `AVAudioPlayer`, call `.play()`
- Implement `AVAudioPlayerDelegate.audioPlayerDidFinishPlaying` → transition to `.idle`
- Implement `AVAudioPlayerDelegate.audioPlayerDecodeErrorDidOccur` → transition to `.error`
- All state transitions publish to `AppState` for menu bar UI updates

### AudioValidator

Checks before playback:
- File exists at path (`FileManager.default.fileExists`)
- File is readable (`FileManager.default.isReadableFile`)
- Extension is in allowed set: `mp3`, `wav`, `m4a`, `aiff`
- Optional: verify file is non-zero size

Returns typed error: `fileNotFound`, `notReadable`, `unsupportedFormat`, `emptyFile`.

### HTTPServer

- Hummingbird 2.x `Application` bound to `127.0.0.1`
- Port from settings (default `9876`)
- JSON request/response via `Codable`
- Routes registered in `APIRoutes` — each handler calls into `PlaybackEngine`
- Server lifecycle tied to app lifecycle (start on launch, stop on quit)
- Log all requests via os.Logger

### MenuBarView

SwiftUI view inside `MenuBarExtra` (macOS 13+) or `NSPopover`:
- Status indicator: colored dot (green=idle, blue=playing, red=error)
- Current file name when playing (truncated)
- Stop button (enabled when playing)
- AVRoutePickerView (wrapped) for AirPlay target selection
- Server status line: `Listening on 127.0.0.1:9876`
- Settings gear icon → opens `SettingsView`
- Quit button

### SettingsView

Small window with:
- Port number field (requires restart of HTTP server)
- Auto-cleanup toggle: delete played files after N minutes
- Launch at login toggle (v2, wire to `SMAppService`)

## State Flow

```
         ┌──────────────────────┐
         │                      │
         ▼                      │
      ┌──────┐   play()    ┌───────┐
      │ idle │─────────────▶│playing│
      └──────┘              └───┬───┘
         ▲                      │
         │  stop() / finished   │  error
         │                      ▼
         │               ┌──────────┐
         └───────────────│  error   │
              stop()     └──────────┘
```

Paused state (stretch): playing ↔ paused via pause()/resume().

## Error Handling

| Scenario | Behavior |
|---|---|
| Invalid file path | Return 400, state stays idle |
| Unsupported format | Return 400, state stays idle |
| File deleted before play | Return 400 on validation |
| AVAudioPlayer decode error | State → error, log, surface in /status |
| HomePod disconnected mid-play | macOS handles route fallback; state still shows playing until finish/error |
| Route not selected | Audio plays through default Mac output — not an error |
| Server bind failure | Log fatal, show error in menu bar, retry on settings change |

## Logging

Use `os.Logger` with subsystem `com.gsmlg.airbridge`:
- Category `http`: all API requests + responses
- Category `playback`: file paths, state transitions, completion, errors
- Category `server`: bind, start, stop, failures

All logs viewable in Console.app with filter `com.gsmlg.airbridge`.

## Security

- HTTP server binds exclusively to `127.0.0.1` — no network exposure
- No authentication required for v1 (localhost-only assumption)
- File access limited to paths the app process can read
- No private Apple APIs used

## Deployment

v1: build with `swift build` or Xcode, run manually.

Later: sign with Developer ID, notarize, distribute as `.app` bundle. Add `SMAppService` for launch-at-login.

## Minimum macOS Version

macOS 13 (Ventura) — required for `MenuBarExtra` in SwiftUI lifecycle.

If macOS 12 support is needed, fall back to `NSStatusItem` + `NSPopover` in AppKit.

## Linux-Side Integration (reference only)

Not part of this project, but the expected caller pattern:

```bash
# Copy file to Mac
scp /tmp/reply.mp3 mac:/tmp/openclaw/reply-123.mp3

# Trigger playback
curl -X POST http://mac-ip:9876/play \
  -H "Content-Type: application/json" \
  -d '{"path": "/tmp/openclaw/reply-123.mp3"}'

# Check status
curl http://mac-ip:9876/status
```

Note: if calling from another machine (not localhost), a future version must add auth and bind to a LAN interface.

## CLAUDE.md (for Claude Code)

Include this in the project root so Claude Code understands the project:

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
curl -X POST http://127.0.0.1:9876/play -H "Content-Type: application/json" -d '{"path":"/path/to/test.mp3"}'
curl http://127.0.0.1:9876/status
curl -X POST http://127.0.0.1:9876/stop
```

## Limitations & Assumptions

- Cannot programmatically select HomePod — user must pick via AVRoutePickerView once
- AirPlay route persistence across app restarts is macOS-managed, not guaranteed
- If Mac audio output is not set to HomePod, audio plays through default speakers — this is expected, not an error
- Large files (>100MB) are not a target use case; no streaming support needed
- No concurrent playback — single file at a time, replacement policy
- File transfer from Linux to Mac is the caller's responsibility