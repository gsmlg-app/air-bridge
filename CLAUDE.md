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
