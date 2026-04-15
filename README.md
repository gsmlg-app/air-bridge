# AirBridge

A lightweight macOS menu bar app that receives audio files via a local HTTP API and plays them through the system audio output, enabling HomePod playback when selected as the AirPlay target.

AirBridge serves as a relay bridge between [OpenClaw](https://github.com/gsmlg-app/openclaw) (running on NixOS/Linux) and Apple HomePod — copy an audio file to the Mac, hit the API, and it plays through whichever AirPlay device the user has selected.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.10+

## Build & Run

```bash
swift build
.build/debug/AirBridge
```

The app appears as a menu bar icon (AirPlay audio symbol). Click it to see playback status, select an AirPlay route, or quit.

## API

All endpoints listen on `127.0.0.1:9876`.

### POST /play

```bash
curl -X POST http://127.0.0.1:9876/play \
  -H "Content-Type: application/json" \
  -d '{"path": "/tmp/openclaw/reply-123.mp3"}'
```

Stops any current playback and starts the new file. Returns 400 if the file doesn't exist, is unreadable, or has an unsupported format.

Supported formats: `mp3`, `wav`, `m4a`, `aiff`

### POST /stop

```bash
curl -X POST http://127.0.0.1:9876/stop
```

### GET /status

```bash
curl http://127.0.0.1:9876/status
```

Returns:
```json
{
  "status": "playing",
  "file": "/tmp/openclaw/reply-123.mp3",
  "route": "System Default",
  "error": null
}
```

Status values: `idle`, `playing`, `paused`, `error`.

## AirPlay Setup

AirBridge cannot programmatically select a HomePod — this is an Apple API limitation. Click the menu bar icon and use the AirPlay route picker to select your HomePod. macOS generally remembers the selection across app restarts.

## Architecture

```
HTTP request → Hummingbird router → PlaybackEngine (actor) → AVAudioPlayer
                                          ↓
                                      AppState → MenuBarView (SwiftUI)
```

- **PlaybackEngine** — Swift actor wrapping AVAudioPlayer with a state machine
- **AppState** — @MainActor ObservableObject bridging engine state to SwiftUI
- **Hummingbird 2.x** — async HTTP server bound to localhost

## Linux-Side Usage (Reference)

```bash
# Copy file to Mac
scp /tmp/reply.mp3 mac:/tmp/openclaw/reply-123.mp3

# Trigger playback
curl -X POST http://mac-ip:9876/play \
  -H "Content-Type: application/json" \
  -d '{"path": "/tmp/openclaw/reply-123.mp3"}'
```

> Note: When calling from another machine, the server currently only binds to localhost. A future version may add authentication and LAN binding.

## License

MIT
