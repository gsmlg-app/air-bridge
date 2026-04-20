---
name: air-bridge
description: "How to use AirBridge — a macOS menu bar audio relay that receives audio via HTTP and plays it through AirPlay / HomePod. Use this skill when the user wants to send audio to AirBridge, interact with its API, manage the playback queue, select an output device, or integrate AirBridge into a Python script or automation. Also trigger when the user mentions 'air-bridge', 'airbridge', playing audio on HomePod from code, or audio relay between machines."
---

# Using AirBridge

AirBridge runs as a macOS menu bar app on `http://127.0.0.1:9876` by default. It accepts audio uploads via multipart HTTP, queues them, and plays through a selected AirPlay device.

Use the CLI tool at `skills/air-bridge/airbridge.py` (Python 3, stdlib only, no dependencies) to interact with AirBridge.

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
| `play` | `<file>` | Upload an audio file and play it immediately (inserts at current+1 and skips) |
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
| `outputs` | | List all discovered AirPlay devices |
| `output` | | Show the currently selected AirPlay device |
| `output-set` | `<id>` | Select an AirPlay device by its Bonjour service ID |

All commands print JSON to stdout. Errors print to stderr and exit with code 1.

Supported audio formats: `mp3`, `wav`, `m4a`, `aiff`. Max 50 MB per file.

## Examples

### Upload and Play Audio

```bash
# Enqueue a file (appends to the end of the queue)
python skills/air-bridge/airbridge.py queue track.mp3

# Play immediately (inserts at current+1 and skips to it)
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

### Output Device Selection

```bash
# List discovered AirPlay devices
python skills/air-bridge/airbridge.py outputs

# Get currently selected device
python skills/air-bridge/airbridge.py output

# Select a device by its Bonjour ID
python skills/air-bridge/airbridge.py output-set BONJOUR-SERVICE-ID
```

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

- **No devices in `outputs`** — Click the AirPlay route button in Settings first so CoreAudio registers HomePods via Bonjour.
- **401 Unauthorized** — Pass `-t TOKEN` if a token is set.
- **Connection refused** — Confirm AirBridge is running and the address/port match. For LAN, listen address must not be `127.0.0.1`.
- **400 unsupported_format** — Only `mp3`, `wav`, `m4a`, `aiff` are accepted.
- **400 file_too_large** — Files over 50 MB are rejected.
