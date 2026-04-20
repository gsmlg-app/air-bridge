# AirBridge

A macOS menu bar app that receives audio files via a local HTTP API, queues them, and plays them through a pinned AirPlay / HomePod output using AVAudioEngine.

AirBridge is a relay bridge between [OpenClaw](https://github.com/gsmlg-app/openclaw) (running on NixOS/Linux) and Apple HomePod — upload an audio file over multipart HTTP, and AirBridge queues and plays it through the HomePod you picked in Settings. The app's engine is pinned to its own output device, so playback never hijacks the system default.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.10+

## Build & Run

```bash
swift build
.build/debug/AirBridge
```

The app appears as a menu bar icon (AirPlay audio symbol); it has no Dock icon (`LSUIElement = true`). Click the icon for queue status, track navigation, the current engine target, and **Settings…** / **Quit**.

## Settings

Open via the **Settings…** button in the menu bar popover.

- **AirPlay Output** — checkbox group of discovered AirPlay / HomePod devices; tick one to pin the engine to it. Use the built-in AirPlay button to discover HomePods first.
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
| `GET /outputs` | List CoreAudio output devices |
| `GET /outputs/current` | Engine's pinned device |
| `PUT /outputs/current` | Set engine target (`{"id": "DEVICE-UID"}`) |

### Examples

```bash
# Enqueue a file
curl -X POST http://127.0.0.1:9876/queue -F "file=@/path/to/track.mp3"

# Play immediately
curl -X POST http://127.0.0.1:9876/play -F "file=@/path/to/alert.mp3"

# Status
curl http://127.0.0.1:9876/status

# Pin to a HomePod (get UIDs from /outputs)
curl -X PUT http://127.0.0.1:9876/outputs/current \
  -H "Content-Type: application/json" \
  -d '{"id":"HomePod-XXXX-UID"}'
```

Supported formats: `mp3`, `wav`, `m4a`, `aiff`. Upload cap: 50 MB per file. Uploaded files are staged to `~/.airbridge/queue/` and cleaned up on remove / stop / quit.

## AirPlay Setup

AirBridge cannot programmatically discover HomePods — you must first trigger Apple's AirPlay picker once so CoreAudio registers them. In **Settings → AirPlay Output**, click the built-in AirPlay route button, pick your HomePod, then tick it in the checkbox list to pin the engine.

## Architecture

```
HTTP multipart upload
  → APIRoutes (Hummingbird 2.x router)
  → MultipartFileParser → FileStaging (~/.airbridge/queue/)
  → PlaybackQueue (actor)
  → PlaybackEngine (actor, AVAudioEngine)
  → pinned CoreAudio output device
                        │
                        ▼ state callback
                   AppState (@MainActor)
                        │
                        ▼
                   MenuBarView / SettingsView (SwiftUI)
```

- **PlaybackEngine** — Swift actor owning AVAudioEngine + AVAudioPlayerNode. Pins output via `kAudioOutputUnitProperty_CurrentDevice`; supports hot-swap during playback.
- **PlaybackQueue** — actor managing ordered tracks with auto-advance.
- **AppState** — `@MainActor ObservableObject`; owns server lifecycle (`startServer` / `stopServer` / `restartServer`), queue sync, and the output-device observer.
- **AudioDeviceManager** — read-only CoreAudio device enumeration using stable UIDs. Never modifies system default.
- **Hummingbird 2.x** — async HTTP server; test harness via `HummingbirdTesting` with port-0 apps.

### Key constraints

- Audio plays on AirBridge's own pinned output — the system default is never changed.
- Server binds to `127.0.0.1` by default; LAN binding requires changing the listen address *and* setting an auth token.
- Device identification uses stable UIDs, not boot-transient `AudioDeviceID`s.
- Logging via `os.Logger`, subsystem `com.gsmlg.airbridge` (categories: `http`, `playback`, `server`, `queue`, `output`).

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
