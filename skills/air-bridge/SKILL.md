---
name: air-bridge
description: "Use AirBridge, a macOS menu bar audio relay that receives audio via HTTP and plays it through selected HomePods or local CoreAudio outputs. Use when the user wants to send audio to AirBridge, call its API, manage playback or queue state, troubleshoot HomePod/AirPlay output, configure multi-HomePod playback, select local outputs, or integrate AirBridge into scripts/automation. Also trigger when the user mentions air-bridge, airbridge, HomePod playback from code, OpenClaw-to-macOS audio relay, or curl uploads to localhost:9876."
---

# Using AirBridge

AirBridge runs as a macOS menu bar app on `http://127.0.0.1:9876` by default. It accepts multipart audio uploads, manages a queue, and plays through either:

- selected HomePods / AirPlay receivers from **Settings > HomePod Output**, using Music.app OS-authenticated AirPlay routing
- a pinned local CoreAudio output selected from **Settings > Audio Output** or `/outputs/current`

Use `skills/air-bridge/airbridge.py` for scriptable API calls. It is Python 3 stdlib only.

## Output Routing Rules

- Use **HomePod Output** checkboxes for multi-HomePod playback. Selecting multiple devices here makes one `/play` request play to all selected HomePods.
- Do not rely on the **System AirPlay picker** for multiroom playback. macOS `AVRoutePickerView` can collapse HomePod selection to one route.
- `/outputs` and `/outputs/current` manage local CoreAudio outputs, not HomePod selection.
- Pinning a local output clears HomePod selection. Selecting a HomePod clears the local output pin.
- The first Music-backed playback may prompt macOS Automation permission. Allow AirBridge to control Music.

## Command Reference

```
airbridge.py [-H HOST] [-p PORT] [-t TOKEN] <command> [args]
```

### Global Options

| Flag | Default | Description |
|------|---------|-------------|
| `-H, --host HOST` | `127.0.0.1` | AirBridge server host |
| `-p, --port PORT` | `9876` | AirBridge server port |
| `-t, --token TOKEN` | *(none)* | Bearer auth token |

### Commands

| Command | Arguments | Description |
|---------|-----------|-------------|
| `play` | `<file>` | Upload an audio file and play it immediately, replacing the current queue with one track |
| `queue` | `<file>` | Upload an audio file and append to the end of the queue |
| `queue-list` | | List all tracks in the queue with id, filename, position, status |
| `queue-next` | | Skip to the next track |
| `queue-prev` | | Go back to the previous track |
| `queue-remove` | `<id>` | Remove a track by its UUID |
| `queue-move` | `<id> <position>` | Move a track to a new 0-based position |
| `status` | | Show playback status (status, track, queue_length, queue_position, output, error) |
| `pause` | | Pause playback |
| `resume` | | Resume playback |
| `stop` | | Stop playback and clear the entire queue |
| `outputs` | | List local CoreAudio output devices and current output state |
| `output` | | Show the current local output target or system default |
| `output-set` | `<id>` | Pin playback to a local CoreAudio output UID |
| `output-clear` | | Clear the local output pin and return to system/HomePod routing |

All commands print JSON to stdout. Errors print to stderr and exit with code 1.

Supported audio formats: `mp3`, `wav`, `m4a`, `aiff`. Max 50 MB per file.

## Examples

### Upload and Play Audio

```bash
# Enqueue a file (appends to the end of the queue)
python skills/air-bridge/airbridge.py queue track.mp3

# Play immediately (replaces queue with this one track)
python skills/air-bridge/airbridge.py play alert.mp3
```

### Check Status

```bash
python skills/air-bridge/airbridge.py status
# Returns JSON: status, track, queue_length, queue_position, output, error
```

### Playback Controls

```bash
python skills/air-bridge/airbridge.py pause
python skills/air-bridge/airbridge.py resume
python skills/air-bridge/airbridge.py stop   # stops playback and clears the queue
```

### Queue Management

```bash
# List tracks
python skills/air-bridge/airbridge.py queue-list

# Skip forward / backward
python skills/air-bridge/airbridge.py queue-next
python skills/air-bridge/airbridge.py queue-prev

# Remove a track by ID
python skills/air-bridge/airbridge.py queue-remove TRACK-UUID

# Reorder a track to a new position
python skills/air-bridge/airbridge.py queue-move TRACK-UUID 0
```

### HomePod and Local Output Selection

```bash
# List local CoreAudio outputs
python skills/air-bridge/airbridge.py outputs

# Get current local output target
python skills/air-bridge/airbridge.py output

# Pin a local output by UID
python skills/air-bridge/airbridge.py output-set CORE-AUDIO-UID

# Clear local pin so HomePod/system routing can be used
python skills/air-bridge/airbridge.py output-clear
```

Select HomePods in the macOS app UI under **Settings > HomePod Output**. Multi-HomePod selection is not exposed through the HTTP API yet.

### LAN / Cross-Machine Usage

When calling from another machine (e.g., OpenClaw on Linux), the AirBridge Settings must be configured for LAN access: set the listen address to `0.0.0.0` (or the Mac's LAN IP), set an auth token, and restart the server.

```bash
# Connect to a remote AirBridge with auth
python skills/air-bridge/airbridge.py -H 192.168.1.50 -t MY_TOKEN status
python skills/air-bridge/airbridge.py -H 192.168.1.50 -t MY_TOKEN queue track.mp3
```

AirBridge advertises itself on the local network as `_air-bridge._tcp` via mDNS/Bonjour. Verify with:

```bash
dns-sd -B _air-bridge._tcp local.
```

## Troubleshooting

- **Only one HomePod plays / another auto-deselects** — Select devices under **HomePod Output**, not the System AirPlay picker. The System picker is single-route on macOS for this app path.
- **Music automation prompt appears** — Choose Allow. If denied, enable AirBridge under macOS System Settings > Privacy & Security > Automation > Music.
- **No HomePods in Settings** — Open Music once, confirm HomePods are visible/available there, then click Refresh in AirBridge's HomePod Output section.
- **No devices in `outputs`** — `/outputs` lists local CoreAudio outputs only. HomePods are selected in the Settings UI.
- **401 Unauthorized** — Pass `-t TOKEN` if a token is set.
- **Connection refused** — Confirm AirBridge is running and the address/port match. For LAN, listen address must not be `127.0.0.1`.
- **400 unsupported_format** — Only `mp3`, `wav`, `m4a`, `aiff` are accepted.
- **400 file_too_large** — Files over 50 MB are rejected.
