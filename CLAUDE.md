# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

AirBridge is a macOS menu bar audio relay app. It receives audio files via multipart HTTP upload (Hummingbird 2.x on 127.0.0.1:9876), queues them, and plays them through a configurable output device using AVAudioEngine with per-engine device pinning. It serves as a bridge between OpenClaw (running on NixOS/Linux) and Apple HomePod or any other CoreAudio output.

## Build & Test

```bash
# Install XcodeGen (one-time)
brew install xcodegen

# Generate Xcode project (run after any project.yml change)
xcodegen generate

# Build (command line)
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge -configuration Debug build

# Build in Xcode
open AirBridge.xcodeproj

# Run tests (via SPM — Xcode test target has NIO linking issues)
swift test

# Run tests matching a name
swift test --filter PlaybackState
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

# Set output device (use Bonjour ID from /outputs)
curl -X PUT http://127.0.0.1:9876/outputs/current -H "Content-Type: application/json" -d '{"id":"BONJOUR-ID"}'

# Queue navigation
curl -X POST http://127.0.0.1:9876/queue/next
curl -X POST http://127.0.0.1:9876/queue/prev

# Pause/resume
curl -X POST http://127.0.0.1:9876/pause
curl -X POST http://127.0.0.1:9876/resume
```

## Architecture

**Data flow:** HTTP multipart upload → `APIRoutes` → `MultipartFileParser` → `FileStaging` (disk) → `PlaybackQueue` (actor) → `PlaybackEngine` (actor) → `AirPlaySession` (actor) → AirPlay device. State changes flow back via callback: `PlaybackEngine` → `AppState` (@MainActor ObservableObject) → `MenuBarView` (SwiftUI).

**Source layout:** `Sources/AirBridge/` is organized into five directories: `App/` (entry point, AppState), `AirPlay/` (protocol stack, Bonjour discovery, HAP pairing), `MenuBar/` (SwiftUI views), `Playback/` (engine, queue, state, validators), `Transport/` (HTTP server, API routes, multipart parser), `Util/` (logging, file staging).

**Key types:**
- `PlaybackEngine` (actor) — wraps `AirPlaySession` for playback. Delegates device selection and audio streaming to the session actor.
- `AirPlaySession` (actor) — manages connection to an AirPlay device, including HAP transient pairing (Phase 2). Resolves Bonjour endpoints via attached `BonjourDiscovery`.
- `BonjourDiscovery` (actor) — browses `_airplay._tcp` and `_raop._tcp` services. Publishes device updates as an `AsyncStream<[AirPlayDevice]>`.
- `AirPlayDevice` — Codable struct parsed from Bonjour TXT records; includes feature bitmask, model ID, AirPlay 2 support flag.
- `PlaybackQueue` (actor) — ordered track list with auto-advance on track completion.
- `AppState` (@MainActor) — bridges actors to SwiftUI via @Published properties. Owns HTTP server lifecycle, Bonjour discovery consumption, queue state sync.
- `PlaybackState` (enum) — `.idle | .playing(file) | .paused(file) | .error(message)`.
- `QueueTrack` / `QueueState` — track metadata and queue state with current index.
- `HAPPairing` / `HAPTLV8` — HAP transient pairing protocol and TLV8 encoding for AirPlay 2 authentication.
- `MultipartFileParser` — extracts files from multipart/form-data uploads using MultipartKit.
- `FileStaging` — manages `~/.airbridge/queue/` directory for uploaded files.
- `AudioValidator` — validates file extensions and paths.

**HTTP layer:** Routes are defined in `APIRoutes.swift` (`buildRouter`). File uploads via multipart/form-data. All routes manually encode JSON responses via a `jsonResponse` helper. `buildTestApplication` creates a port-0 app for HummingbirdTesting. Auth middleware gates all routes when a bearer token is configured.

## Key Constraints

- Audio plays on AirBridge's own pinned output device — system default is never modified
- HTTP server binds to `127.0.0.1` by default; LAN binding requires explicit `listenAddress` change + auth token
- HomePods are discovered via Bonjour (`_airplay._tcp` / `_raop._tcp`); user must first trigger AVRoutePickerView so CoreAudio registers them, then AirBridge can target them via API
- Queue with auto-advance; `/play` inserts at current+1 and skips to it
- Supported formats: mp3, wav, m4a, aiff
- Upload size cap: 50 MB per file
- Uploaded files staged to `~/.airbridge/queue/`, cleaned up on remove/stop/quit
- Device identification uses Bonjour service IDs (stable across reboots)
- AirPlay 2 protocol integration is phased: Phase 1 (Bonjour discovery + session skeleton) is complete; Phases 2–5 (HAP pairing, RTSP negotiation, audio streaming) are in progress
- Minimum macOS 14 (Sonoma) — uses MenuBarExtra with `.window` style
- `LSUIElement = true` — no Dock icon, menu bar only
- Logging via `os.Logger` with subsystem `com.gsmlg.airbridge` (categories: http, playback, server, queue, output)
