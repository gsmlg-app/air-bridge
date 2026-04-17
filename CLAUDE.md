# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

AirBridge is a macOS menu bar audio relay app. It receives audio files via multipart HTTP upload (Hummingbird 2.x on 127.0.0.1:9876), queues them, and plays them through a configurable output device using AVAudioEngine with per-engine device pinning. It serves as a bridge between OpenClaw (running on NixOS/Linux) and Apple HomePod or any other CoreAudio output.

## Build & Test

```bash
swift build                              # debug build
swift build -c release                   # release build
swift test                               # run all tests
swift test --filter PlaybackState        # run tests matching a name
swift test --filter AudioValidator       # run tests matching a name
swift test --filter APIRoutes            # run API route tests (uses HummingbirdTesting)
swift test --filter PlaybackQueue        # run queue actor tests
swift test --filter FileStaging          # run file staging tests
.build/debug/AirBridge                   # run the app
```

Manual API testing:
```bash
# Upload and enqueue
curl -X POST http://127.0.0.1:9876/queue -F "file=@/path/to/test.mp3"

# Upload and play immediately
curl -X POST http://127.0.0.1:9876/play -F "file=@/path/to/test.mp3"

# Check status
curl http://127.0.0.1:9876/status

# Check queue
curl http://127.0.0.1:9876/queue

# Stop and clear queue
curl -X POST http://127.0.0.1:9876/stop

# List output devices
curl http://127.0.0.1:9876/outputs

# Set output device
curl -X PUT http://127.0.0.1:9876/outputs/current -H "Content-Type: application/json" -d '{"id":"DEVICE-UID"}'

# Queue navigation
curl -X POST http://127.0.0.1:9876/queue/next
curl -X POST http://127.0.0.1:9876/queue/prev

# Pause/resume
curl -X POST http://127.0.0.1:9876/pause
curl -X POST http://127.0.0.1:9876/resume
```

## Architecture

**Data flow:** HTTP multipart upload → `APIRoutes` → `MultipartFileParser` → `FileStaging` (disk) → `PlaybackQueue` (actor) → `PlaybackEngine` (actor, AVAudioEngine) → CoreAudio output device. State changes flow back via callback: `PlaybackEngine` → `AppState` (@MainActor ObservableObject) → `MenuBarView` (SwiftUI).

**Key types:**
- `PlaybackEngine` (actor) — owns AVAudioEngine + AVAudioPlayerNode. Pins output to a specific device via `kAudioOutputUnitProperty_CurrentDevice`. Supports hot-swap during playback.
- `PlaybackQueue` (actor) — ordered track list with auto-advance on track completion. Coordinates with PlaybackEngine for playback.
- `AppState` (@MainActor) — bridges actors to SwiftUI via @Published properties. Owns HTTP server lifecycle, queue state sync, and output device observer.
- `PlaybackState` (enum) — `.idle | .playing(file) | .paused(file) | .error(message)`.
- `QueueTrack` / `QueueState` — track metadata and queue state with current index.
- `AudioDeviceManager` — read-only CoreAudio device enumeration using stable UIDs. Never modifies system default.
- `OutputDeviceObserver` — CoreAudio property listener for system default output changes.
- `MultipartFileParser` — extracts files from multipart/form-data uploads using MultipartKit.
- `FileStaging` — manages `~/.airbridge/queue/` directory for uploaded files.
- `AudioValidator` — validates file extensions and paths.

**HTTP layer:** Routes are defined in `APIRoutes.swift` (`buildRouter`). File uploads via multipart/form-data. All routes manually encode JSON responses via a `jsonResponse` helper. `buildTestApplication` creates a port-0 app for HummingbirdTesting.

## Key Constraints

- Audio plays on AirBridge's own pinned output device — system default is never modified
- HTTP server binds to `127.0.0.1` by default; LAN binding requires explicit `listenAddress` change + auth token
- Cannot programmatically select HomePod — user must pick via AVRoutePickerView to register it with CoreAudio, then AirBridge can target it via API
- Queue with auto-advance; `/play` inserts at current+1 and skips to it
- Supported formats: mp3, wav, m4a, aiff
- Upload size cap: 50 MB per file
- Uploaded files staged to `~/.airbridge/queue/`, cleaned up on remove/stop/quit
- Device identification uses stable UIDs (not boot-transient AudioDeviceID)
- Minimum macOS 14 (Sonoma) — uses MenuBarExtra with `.window` style
- `LSUIElement = true` — no Dock icon, menu bar only
- Logging via `os.Logger` with subsystem `com.gsmlg.airbridge` (categories: http, playback, server, queue, output)
