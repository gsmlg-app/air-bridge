# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

AirBridge is a macOS menu bar audio relay app. It receives audio files via a local HTTP API (Hummingbird 2.x on 127.0.0.1:9876) and plays them through the system audio output, enabling HomePod playback when selected as the AirPlay target. It serves as a bridge between OpenClaw (running on NixOS/Linux) and Apple HomePod.

## Build & Test

```bash
swift build                              # debug build
swift build -c release                   # release build
swift test                               # run all tests
swift test --filter PlaybackState        # run tests matching a name
swift test --filter AudioValidator       # run tests matching a name
swift test --filter APIRoutes            # run API route tests (uses HummingbirdTesting)
.build/debug/AirBridge                   # run the app
```

Manual API testing:
```bash
curl -X POST http://127.0.0.1:9876/play -H "Content-Type: application/json" -d '{"path":"/path/to/test.mp3"}'
curl http://127.0.0.1:9876/status
curl -X POST http://127.0.0.1:9876/stop
```

## Architecture

**Data flow:** HTTP request → `APIRoutes` (Hummingbird router) → `PlaybackEngine` (actor) → `AVAudioPlayer`. State changes flow back via callback: `PlaybackEngine` → `AppState` (@MainActor ObservableObject) → `MenuBarView` (SwiftUI).

**Key types:**
- `PlaybackEngine` (actor) — owns the AVAudioPlayer and state machine. Uses a separate `PlayerDelegate` class to bridge AVAudioPlayerDelegate (NSObject-based) to actor isolation. All playback operations go through this actor.
- `AppState` (@MainActor) — bridges PlaybackEngine to SwiftUI via @Published properties. Also owns the HTTP server lifecycle (starts in init via `Task.detached`).
- `PlaybackState` (enum) — `.idle | .playing(file) | .paused(file) | .error(message)`. Shared by engine, API responses, and UI.
- `AudioValidator` — validates file path before playback (existence, readability, extension, non-empty).

**HTTP layer:** Routes are defined as free functions in `APIRoutes.swift` (`buildRouter`). All routes manually encode JSON responses via a `jsonResponse` helper rather than using Hummingbird's ResponseCodable protocol. `buildTestApplication` creates a port-0 app for HummingbirdTesting.

## Key Constraints

- HTTP server binds exclusively to `127.0.0.1` — no network exposure
- Cannot programmatically select HomePod — user must pick via AVRoutePickerView in the menu bar
- Replacement policy: new `/play` request stops current playback immediately
- Supported formats: mp3, wav, m4a, aiff
- Minimum macOS 14 (Sonoma) — uses MenuBarExtra with `.window` style
- `LSUIElement = true` — no Dock icon, menu bar only
- Logging via `os.Logger` with subsystem `com.gsmlg.airbridge` (categories: http, playback, server)
