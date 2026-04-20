---
name: air-bridge
description: "How to use AirBridge — a macOS menu bar audio relay that receives audio via HTTP and plays it through AirPlay / HomePod. Use this skill when the user wants to send audio to AirBridge, interact with its API, manage the playback queue, select an output device, or integrate AirBridge into a Python script or automation. Also trigger when the user mentions 'air-bridge', 'airbridge', playing audio on HomePod from code, or audio relay between machines."
---

# Using AirBridge

AirBridge runs as a macOS menu bar app on `http://127.0.0.1:9876` by default. It accepts audio uploads via multipart HTTP, queues them, and plays through a selected AirPlay device. All examples below use Python with `requests`.

## Upload and Play Audio

```python
import requests

BASE = "http://127.0.0.1:9876"
# If auth is enabled:
# HEADERS = {"Authorization": "Bearer YOUR_TOKEN"}
# Pass headers=HEADERS to every call.

# Enqueue a file (appends to the end of the queue)
with open("track.mp3", "rb") as f:
    r = requests.post(f"{BASE}/queue", files={"file": f})
print(r.json())  # {"id": "...", "filename": "track.mp3", "position": 2, "queue_length": 3}

# Play immediately (inserts at current+1 and skips to it)
with open("alert.mp3", "rb") as f:
    r = requests.post(f"{BASE}/play", files={"file": f})
print(r.json())  # {"id": "...", "filename": "alert.mp3", "status": "playing", "queue_length": 4}
```

Supported formats: `mp3`, `wav`, `m4a`, `aiff`. Max 50 MB per file.

## Check Status

```python
r = requests.get(f"{BASE}/status")
print(r.json())
# {
#   "status": "playing",
#   "track": {"id": "...", "filename": "track.mp3"},
#   "queue_length": 3,
#   "queue_position": 0,
#   "output": {"airplay_device_id": "...", "airplay_device_name": "Living Room"},
#   "error": null
# }
```

## Playback Controls

```python
requests.post(f"{BASE}/pause")
requests.post(f"{BASE}/resume")
requests.post(f"{BASE}/stop")   # stops playback and clears the queue
```

## Queue Management

```python
# List tracks
r = requests.get(f"{BASE}/queue")
tracks = r.json()["tracks"]
# Each track: {"id": "uuid", "filename": "...", "position": 0, "status": "playing"|"played"|"queued"}

# Skip forward / backward
requests.post(f"{BASE}/queue/next")
requests.post(f"{BASE}/queue/prev")

# Remove a track by ID
requests.delete(f"{BASE}/queue/{track_id}")

# Reorder a track to a new position
requests.post(f"{BASE}/queue/move", json={"id": track_id, "position": 0})
```

## Output Device Selection

```python
# List discovered AirPlay devices
r = requests.get(f"{BASE}/outputs")
for d in r.json()["devices"]:
    print(d["id"], d["name"], "selected" if d["is_selected"] else "")

# Get currently selected device
r = requests.get(f"{BASE}/outputs/current")

# Select a device by its Bonjour ID
requests.put(f"{BASE}/outputs/current", json={"id": "BONJOUR-SERVICE-ID"})
```

## LAN / Cross-Machine Usage

When calling from another machine (e.g., OpenClaw on Linux), the AirBridge Settings must be configured for LAN access: set the listen address to `0.0.0.0` (or the Mac's LAN IP), set an auth token, and restart the server.

```python
import requests

BASE = "http://mac-ip:9876"
HEADERS = {"Authorization": "Bearer YOUR_TOKEN"}

with open("/tmp/reply.mp3", "rb") as f:
    r = requests.post(f"{BASE}/queue", files={"file": f}, headers=HEADERS)
print(r.json())
```

## Troubleshooting

- **No devices in `/outputs`** — Click the AirPlay route button in Settings first so CoreAudio registers HomePods via Bonjour.
- **401 Unauthorized** — Include `Authorization: Bearer <token>` if a token is set.
- **Connection refused** — Confirm AirBridge is running and the address/port match. For LAN, listen address must not be `127.0.0.1`.
- **400 unsupported_format** — Only `mp3`, `wav`, `m4a`, `aiff` are accepted.
- **400 file_too_large** — Files over 50 MB are rejected.
