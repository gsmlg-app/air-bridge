# AirBridge

A macOS menu bar app that receives audio files via a local HTTP API, queues them, and plays them through a selected AirPlay / HomePod output.

AirBridge is a relay bridge between [OpenClaw](https://github.com/gsmlg-app/openclaw) (running on NixOS/Linux) and Apple HomePod — upload an audio file over multipart HTTP, and AirBridge queues and plays it through the AirPlay device you picked in Settings. Devices are discovered via Bonjour and targeted by stable service IDs.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.10+

## Build

```bash
# Install XcodeGen (one-time)
brew install xcodegen

# Generate Xcode project
xcodegen generate

# Open in Xcode
open AirBridge.xcodeproj

# Or build from command line
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge build

# Run tests
swift test
```

## Run

The app is built as an Xcode project with Mac App Store entitlements and App Sandbox enabled. Open the project in Xcode and press Cmd+R to run, or open the built `.app` bundle from `build/Release/AirBridge.app`.

The app appears as a menu bar icon (AirPlay audio symbol); it has no Dock icon (`LSUIElement = true`). Click the icon for queue status, track navigation, the current engine target, and **Settings…** / **Quit**.

## Settings

Open via the **Settings…** button in the menu bar popover.

- **AirPlay Output** — list of AirPlay / HomePod devices discovered via Bonjour (`_airplay._tcp` / `_raop._tcp`); select one to target the engine. Use the built-in AirPlay route button to register HomePods with CoreAudio first.
- **Server** — listen address (default `127.0.0.1`) and port (default `9876`).
- **Authentication** — optional bearer token; leave empty to disable. Includes a **Generate** button that produces a 32-character URL-safe random token.
- **Restart Server** — applies address / port / token changes without quitting the app.

## API

All endpoints default to `127.0.0.1:9876`. If an auth token is set, include `Authorization: Bearer <token>` on every request.

### Playback

| Method & Path | Description |
|---|---|
| `POST /queue` | Upload (multipart `file=@…`) and append to the queue |
| `POST /play`  | Upload and play immediately (inserts at current+1, skips) |
| `POST /pause` | Pause current track |
| `POST /resume` | Resume paused track |
| `POST /stop` | Stop playback and clear the queue |
| `GET /status` | Current playback state |

### Queue

| Method & Path | Description |
|---|---|
| `GET /queue` | List queued tracks with current index |
| `DELETE /queue/:id` | Remove a track by id |
| `POST /queue/next` | Skip to next track |
| `POST /queue/prev` | Skip to previous track |
| `POST /queue/move` | Reorder a track (`{"id": "...", "to": N}`) |

### Output devices

| Method & Path | Description |
|---|---|
| `GET /outputs` | List discovered AirPlay devices |
| `GET /outputs/current` | Currently selected AirPlay device |
| `PUT /outputs/current` | Select AirPlay device by Bonjour ID (`{"id": "BONJOUR-ID"}`) |

### Examples

```bash
# Enqueue a file
curl -X POST http://127.0.0.1:9876/queue -F "file=@/path/to/track.mp3"

# Play immediately
curl -X POST http://127.0.0.1:9876/play -F "file=@/path/to/alert.mp3"

# Status
curl http://127.0.0.1:9876/status

# Pin to a HomePod (get Bonjour IDs from /outputs)
curl -X PUT http://127.0.0.1:9876/outputs/current \
  -H "Content-Type: application/json" \
  -d '{"id":"BONJOUR-SERVICE-ID"}'
```

Supported formats: `mp3`, `wav`, `m4a`, `aiff`. Upload cap: 50 MB per file. Uploaded files are staged to `~/.airbridge/queue/` and cleaned up on remove / stop / quit.

## AirPlay Setup

AirBridge discovers AirPlay devices via Bonjour (`_airplay._tcp` and `_raop._tcp`). For HomePods, you must first trigger Apple's AirPlay picker once so CoreAudio registers them. In **Settings → AirPlay Output**, click the built-in AirPlay route button, pick your HomePod, then select it in the device list.

## Architecture

```
HTTP multipart upload
  → APIRoutes (Hummingbird 2.x router)
  → MultipartFileParser → FileStaging (~/.airbridge/queue/)
  → PlaybackQueue (actor)
  → PlaybackEngine (actor)
  → AirPlaySession (actor, HAP pairing)
  → AirPlay device (HomePod / Apple TV / etc.)
                        │
                        ▼ state callback
                   AppState (@MainActor)
                        │
                        ▼
                   MenuBarView / SettingsView (SwiftUI)

BonjourDiscovery (actor)
  → browses _airplay._tcp / _raop._tcp
  → AsyncStream<[AirPlayDevice]> → AppState → SettingsView
```

- **PlaybackEngine** — Swift actor wrapping `AirPlaySession`; delegates playback and device selection to the session.
- **AirPlaySession** — actor managing AirPlay device connection, including HAP transient pairing for AirPlay 2 devices.
- **BonjourDiscovery** — actor browsing Bonjour for AirPlay devices; publishes updates as an async stream.
- **PlaybackQueue** — actor managing ordered tracks with auto-advance.
- **AppState** — `@MainActor ObservableObject`; owns server lifecycle, Bonjour discovery consumption, queue sync.
- **Hummingbird 2.x** — async HTTP server; test harness via `HummingbirdTesting` with port-0 apps.

### Key constraints

- Audio plays on the selected AirPlay device — the system default is never changed.
- Server binds to `127.0.0.1` by default; LAN binding requires changing the listen address *and* setting an auth token.
- Device identification uses stable Bonjour service IDs.
- AirPlay 2 protocol integration is phased: Phase 1 (Bonjour discovery + session skeleton) is complete.
- Logging via `os.Logger`, subsystem `com.gsmlg.airbridge` (categories: `http`, `playback`, `server`, `queue`, `output`).

## Mac App Store Distribution

AirBridge is configured for distribution via the Mac App Store with **App Sandbox** enabled. The project's entitlements and code signing are pre-configured to pass App Store review. To submit, generate a Release build in Xcode and follow Apple's standard App Store submission workflow.

## Tests

```bash
swift test                              # all tests
swift test --filter APIRoutes           # specific suite
swift test --filter PlaybackQueue
```

## Linux-Side Usage

```bash
# Upload and play
curl -X POST http://mac-ip:9876/queue \
  -H "Authorization: Bearer $AIRBRIDGE_TOKEN" \
  -F "file=@/tmp/reply.mp3"
```

When calling from another machine, set a listen address other than `127.0.0.1` in Settings and set an auth token.

## License

MIT
