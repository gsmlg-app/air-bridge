# Multi-Device AirPlay Output — Data Model & API (Sub-project A)

**Status:** Approved for planning
**Date:** 2026-04-21
**Scope:** Sub-project A of the "multi-device simultaneous AirPlay playback" feature.

## Context

Today AirBridge targets exactly one AirPlay device. `AirPlaySession` (actor) holds
one `selectedDevice` and one `HAPSessionKeys`. `PlaybackEngine` wraps one session.
`AppState.selectedDevice` is a single optional, persisted via UserDefaults key
`selectedAirPlayDeviceID`. HTTP exposes singular `GET/PUT /outputs/current`.
`StatusResponse.OutputInfo` carries one device.

The user wants to stream the same audio to several AirPlay speakers simultaneously
(kitchen + living room HomePods, etc.). That is the full-scope goal.

The full-scope goal requires, roughly:

1. Multi-device **data model, API, persistence, UI** (this document)
2. **RTSP** control-channel client against one device
3. **NTP/PTP timing** and **RTP** audio transport (with AEAD using HAP keys)
4. **Audio decode pipeline** (mp3/m4a/aiff → PCM → ALAC frames)
5. **Single-device end-to-end playback**
6. **Multi-device fan-out** with shared master clock and synchronized start

Each piece gets its own spec → plan → implementation. This document covers only
piece (1). The app will still produce no audio after this sub-project merges —
that is deliberate and tracked by sub-projects B–F.

## Goals

- Let the user select **1..8 AirPlay devices** and persist that set.
- Expose selection through HTTP as an ordered array, with legacy singular
  endpoints preserved so existing OpenClaw integrations keep working.
- Proactively pair each selected device via HAP so errors surface in Settings,
  not mid-song (once sound plays).
- Per-device status (`pairing | ok | offline | error`) is first-class and
  surfaced in API + UI.
- One device's pairing failure does not affect the others.
- No change to the streaming story. `PlaybackEngine.play()` still throws
  `notImplemented(phase: .rtsp)` — now for every selected session, via a fan-out
  loop that tolerates partial failure.

## Non-goals

- RTSP, timing sync, RTP, AEAD-encrypted audio, audio decode — all in sub-projects B–F.
- Synchronized multi-device playback — sub-project F.
- Reorderable selection UI (the model supports ordered arrays; the Settings view
  in this sub-project does not yet expose reorder gestures).
- Stereo L/R pairing, per-device volume, device groups/presets.

## Design decisions

| # | Decision | Reason |
|---|---|---|
| 1 | **Additive** API: new plural `/outputs/selected`, keep `/outputs/current` as alias | OpenClaw integration keeps working unchanged. |
| 2 | Offline devices stay in the set, mark `offline`, auto-retry on Bonjour reappearance | "My kitchen HomePods" shouldn't vanish when they reboot. |
| 3 | **Proactive** pairing on select (not lazy) | Fast first-play; errors surface in Settings, not mid-song. |
| 4 | **Ordered Array**, not Set | Unblocks stereo L/R, display priority, etc. without a later migration. |
| 5 | Per-device **error isolation** | One bad device does not invalidate the user's whole selection. |
| 6 | **Cap at 8** selected devices | Matches Apple's multi-room AirPlay limit; rejects accidental fan-out. |
| 7 | **Keep existing Settings UI style**, add multi-check + per-row status | Minimal UI churn; familiar interaction model. |
| 8 | **One `AirPlaySession` per device**, engine owns `[deviceID: AirPlaySession]` | Smallest diff; session stays single-device internally; no per-session rewrite. |

## Architecture overview

```
                    ┌────────────────┐        ┌──────────────────┐
     Bonjour ──────▶│ BonjourDiscovery│◀──────│ PlaybackEngine   │
                    └────────┬───────┘        │  [id: Session]   │
                             │                │  order: [id]     │
                             ▼                │  statuses: [...] │
                       AppState               └────────┬─────────┘
                       selectedDevices: [SelectedDevice]│
                             │                          ▼
                             ▼                    AirPlaySession  (× N)
                       SwiftUI (MenuBar, Settings)      (each single-device,
                                                        unchanged internally)
                             │
             HTTP ◀──────────┤ /outputs, /outputs/selected, /outputs/current, /status
```

Data flows unchanged except selection is now an array. Sessions are created and
torn down inside `PlaybackEngine` as the selected array changes.

## Data model

### New types

```swift
// Sources/AirBridge/AirPlay/SelectedDevice.swift
struct SelectedDevice: Identifiable, Sendable, Hashable, Codable {
    let id: String              // Bonjour instance name (stable)
    let displayName: String     // snapshot of .displayName at selection time
    var status: DeviceStatus
}

enum DeviceStatus: Sendable, Hashable, Codable {
    case pairing
    case ok
    case offline
    case error(reason: String)
}
```

`displayName` is cached on the `SelectedDevice` so a temporarily-offline device
still has something to show in the menu bar / Settings list. When Bonjour emits
an update carrying the same `id` with a different `displayName` (the user
renamed the HomePod), `PlaybackEngine` refreshes the cached name so stale
labels don't persist. The id itself is stable and is always the source of truth.

### Removed / changed

- `AppState.selectedDevice: AirPlayDevice?` → `AppState.selectedDevices: [SelectedDevice]`.
- `AppState.selectAirPlayDevice(_:)` → `AppState.setSelectedDevices(_ ids: [String])`
  plus `AppState.toggleSelection(_ device: AirPlayDevice)` for the Settings UI.

### Persistence migration

UserDefaults key change: `selectedAirPlayDeviceID: String`
→ `selectedAirPlayDeviceIDs: String` (JSON-encoded `[String]`).

Migration logic runs once in `AppState.init`:

1. If `selectedAirPlayDeviceIDs` exists → decode as `[String]`, use it.
2. Else if `selectedAirPlayDeviceID` is set and non-empty → `[legacyID]`, write
   new key, clear old key.
3. Else → empty selection.

### Invariants

- `selectedDevices.count <= 8`. Violations return HTTP 400 `too_many_devices`;
  the UI disables unchecked rows once full.
- Elements are unique by `id`. Adding a duplicate is a no-op, not an error.
- Order is preserved across persistence and API round-trips.

## Actor layout

### `AirPlaySession` — unchanged

Still a single-device actor. One instance per selected target.

### `PlaybackEngine` — changed

```swift
actor PlaybackEngine {
    private(set) var state: PlaybackState = .idle
    private var sessions: [String: AirPlaySession] = [:]
    private var order: [String] = []
    private var deviceSnapshots: [String: AirPlayDevice] = [:]
    private var statuses: [String: DeviceStatus] = [:]
    private weak var discovery: BonjourDiscovery?

    private var statusCallback: (@Sendable ([SelectedDevice]) -> Void)?
    // existing: stateCallback, trackFinishedCallback

    // Factory seam — injected for tests that need to stub pairing.
    var sessionFactory: @Sendable () -> AirPlaySession = { AirPlaySession() }
}
```

### Key methods

```swift
// Diffs current vs requested; creates/tears down sessions; proactively pairs new.
func setSelectedDevices(_ devices: [AirPlayDevice]) async

// Read-only snapshot for UI/API.
func selectedDevices() -> [SelectedDevice]

// Re-attempt pairing. Called on Bonjour reappearance or a manual Retry click.
func retry(deviceID: String) async

// Mark a selected device offline (does not remove it).
func markOffline(deviceID: String) async

// Legacy compatibility (unchanged signatures, new behavior).
func setDevice(_ device: AirPlayDevice?) async
var currentDevice: AirPlayDevice? { get async }   // first selected
```

### Selection diff algorithm

Inside `setSelectedDevices`:

1. `toRemove = currentIDs \ requestedIDs`. For each: `await session.stop()`;
   remove from `sessions`, `statuses`, `deviceSnapshots`.
2. `toAdd = requestedIDs \ currentIDs`. For each:
   - Create `AirPlaySession` via `sessionFactory`, `attachDiscovery`, `setDevice(d)`.
   - Record `deviceSnapshots[d.id] = d`, `statuses[d.id] = .pairing`.
   - Fire `statusCallback` so UI flips to `pairing`.
   - Spawn an unstructured `Task` that calls `session.connect()`:
     - On success → `statuses[d.id] = .ok`; fire callback.
     - On `AirPlayError` → `statuses[d.id] = .error(reason: ...)`; fire callback.
   - If `d.supportsAirPlay2 == false` → immediately set
     `.error(reason: "AirPlay 2 required")`, skip `connect()`.
3. Replace `order` with `requestedIDs` (preserving user-chosen order).
4. Fire `statusCallback` with final snapshot.

### Bonjour updates

`AppState` already observes `discovery.updates()`. Extended behavior:

- For each selected `id` **not** in the new Bonjour snapshot: call
  `await engine.markOffline(deviceID: id)`.
- For each `offline` device that reappears: call
  `await engine.retry(deviceID: id)`.

### `play()` fan-out (shape-of-future)

```swift
func play(track: QueueTrack) async throws {
    let url = URL(fileURLWithPath: track.stagedPath)
    var errors: [String: Error] = [:]
    await withTaskGroup(of: (String, Error?).self) { group in
        for id in order {
            guard let session = sessions[id] else { continue }
            group.addTask {
                do { try await session.play(fileURL: url); return (id, nil) }
                catch { return (id, error) }
            }
        }
        for await (id, err) in group { if let err { errors[id] = err } }
    }
    if errors.count == order.count, !order.isEmpty {
        // All sessions failed. Use the first error as representative for the
        // thrown value; the rest are logged.
        let first = errors.first!
        transition(to: .error(message: "All devices failed; first=\(first.key): \(first.value)"))
        throw first.value
    } else {
        transition(to: .playing(file: track.originalFilename))
    }
}
```

Every branch throws today because `AirPlaySession.play` still throws
`notImplemented(phase: .rtsp)`. The fan-out shape is in place so sub-projects
E/F don't need a rewrite here — they'll replace the error inside
`AirPlaySession.play` with real RTSP+RTP, and this engine loop keeps working.

## HTTP API

### New plural endpoints (canonical)

```
GET  /outputs/selected
  200 OK
  {
    "max": 8,
    "devices": [
      { "id": "...", "name": "...", "model": "...", "supports_airplay_2": true,
        "status": "ok", "status_reason": null, "online": true }
    ]
  }

PUT  /outputs/selected
  body: { "ids": ["...", "..."] }
  200 OK     — same body shape as GET /outputs/selected
  400 { "error": "too_many_devices",  "message": "max 8 devices (got 9)" }
  400 { "error": "duplicate_ids",     "message": "id '...' appears twice" }
  400 { "error": "invalid_request",   "message": "missing 'ids' array" }
  404 { "error": "device_not_found",  "message": "No AirPlay device with id: ..." }
```

Empty `ids: []` is valid and clears the selection.

### Legacy aliases (unchanged paths and **unchanged response shape**, documented as deprecated)

```
GET  /outputs/current
  200 OK    first selected device in the EXISTING OutputCurrentResponse shape
            { id, name, model, supports_airplay_2 }
  404 { "error": "none_selected", "message": "No AirPlay device selected" }

PUT  /outputs/current
  body: { "id": "..." }
  → behavior: replaces entire selected array with [id]
  → response: same OutputCurrentResponse shape as today
  → error codes inherited from PUT /outputs/selected
```

Legacy shape is preserved verbatim; no `status` / `status_reason` / `online`
fields on the legacy response. Clients that want the richer view migrate to
`/outputs/selected`.

### Changes to existing endpoints

`GET /outputs` (device list):

- Each `AirPlayDeviceInfo` row gains:
  - `is_selected: Bool` (already present, semantics unchanged — true iff in selection)
  - `selected_order: Int?` — index in the selected array (0-based), or null when not selected
- Top-level `selected:` is **kept unchanged** — still `AirPlayDeviceInfo?` set to
  the first selected device (or null). Legacy consumers of `GET /outputs` see
  no shape change.
- New top-level field `selected_devices: [...]` — array of
  SelectedDevice-shaped rows (with `status`, `online`, etc.). Richer view for
  new clients.

`GET /status`:

```json
{
  "status": "idle",
  "track": null,
  "queue_length": 0,
  "queue_position": null,
  "output": {
    "airplay_device_id": "...",
    "airplay_device_name": "..."
  },
  "outputs": [
    { "id": "...", "name": "...", "status": "ok",      "online": true  },
    { "id": "...", "name": "...", "status": "offline", "online": false }
  ],
  "error": null
}
```

`output` mirrors the first selected device (or `null`). `outputs` lists all.
Both present for one release; `output` will be removed later with notice.

### Per-device response shape (shared)

```json
{
  "id": "HomePod-Kitchen._airplay._tcp.",
  "name": "Kitchen HomePod",
  "model": "AudioAccessory5,1",
  "supports_airplay_2": true,
  "status": "ok",
  "status_reason": null,
  "online": true
}
```

`status` ∈ `"pairing" | "ok" | "offline" | "error"`; `status_reason` populated
only when `status == "error"`.

## Settings UI

Same checkbox list; multi-select enabled; per-row status badge.

```
┌─ AirPlay Output ─────────────────────────────────────┐
│                                                       │
│  ☑ Living Room HomePod  (AudioAccessory5,1) [AP2] ● ok│
│  ☑ Kitchen HomePod      (AudioAccessory5,1) [AP2] ◐ pairing │
│  ☐ Bedroom HomePod      (AudioAccessory1,1)       ○ offline │
│  ☑ Apple TV 4K          (AppleTV6,2)        [AP2] ⚠ error  │
│      └ HAP pairing failed: timeout        [Retry]     │
│  ☐ Living Room TV       (AppleTV11,1)       [AP2]     │
│                                                       │
│  3 of 8 selected                    5 device(s) found │
└───────────────────────────────────────────────────────┘
```

Details:

- Row toggle binding switches from single-select to array membership. Toggling
  calls `appState.toggleSelection(_:)`.
- Trailing status glyph: green `●` ok, yellow animated `◐` pairing, gray `○`
  offline, red `⚠` error.
- Error rows expand to show `status_reason` and a `Retry` button calling
  `engine.retry(deviceID:)`.
- Once `selectedDevices.count == 8`, unchecked rows are `.disabled(true)` with
  tooltip `"Max 8 devices selected."`
- Footer: `"N of 8 selected"` on the left, `"M device(s) found"` on the right.

## Menu bar

`MenuBarView`'s single "Kitchen HomePod" row becomes:

- 0 selected → "No AirPlay device" (orange, as today).
- 1 selected → "Kitchen HomePod" — plus "(error)" / "(offline)" suffix when
  applicable.
- N>1 selected → `<first display name> +<N-1>`, e.g. `"Kitchen HomePod +2"`.

No new interaction — Settings is still where selection happens.

## Error handling & edge cases

| Case | Behavior |
|---|---|
| Duplicate IDs in `PUT /outputs/selected` | 400 `duplicate_ids`, no state change |
| 9+ IDs in body | 400 `too_many_devices`, no state change |
| ID unknown to Bonjour right now (HTTP PUT) | 404 `device_not_found` for that id; no state change (consistent with today's `PUT /outputs/current`) |
| Previously-selected ID not yet re-seen on relaunch | Persistence-restore path accepts it: device enters selection with cached `displayName` and status `.offline`; moves to `.pairing` when Bonjour surfaces it. HTTP API does **not** accept unknown IDs — the offline path is persistence-only. |
| Device where `supportsAirPlay2 == false` | Accepted with immediate `error("AirPlay 2 required")`; no pairing attempt |
| Device surfaced by both `_airplay._tcp` and `_raop._tcp` | `BonjourDiscovery` already de-dupes |
| Quit with 3 devices selected | Persisted; relaunch restores; each attempts pairing |
| Legacy `selectedAirPlayDeviceID` on disk | Migrated on first run |
| `PUT /outputs/current` with empty/missing id | 400 `invalid_request` (existing) |
| Concurrent PUTs | `AppState.setSelectedDevices` is `@MainActor`; last-writer-wins; clients see final state via GET |
| Status transitions | see table below |

Status transitions:

```
nothing   ─(select)──────────▶  .pairing
.pairing  ─(connect ok)──────▶  .ok
.pairing  ─(AirPlayError)────▶  .error(reason)
.ok       ─(bonjour lost)────▶  .offline
.error    ─(bonjour lost)────▶  .offline
.offline  ─(bonjour back)────▶  .pairing  (auto-retry)
any       ─(user deselects)──▶  (removed; session.stop())
```

## Testing

No new dependencies. Everything is testable without a real HomePod thanks to
the injected `sessionFactory`.

| Target | Coverage |
|---|---|
| `SelectedDeviceTests` (new) | Codable roundtrip; `DeviceStatus` encode/decode; migration from legacy single-ID key to new array key |
| `PlaybackEngineTests` (new) | `setSelectedDevices` diff (add-only, remove-only, mixed); order preserved; status transitions via stub `sessionFactory`; `retry(deviceID:)` returns to `.pairing`; `markOffline(deviceID:)` flips status but keeps element |
| `APIRoutesTests` (extend) | `GET /outputs/selected` empty + populated; `PUT /outputs/selected` happy path, 0 IDs (clear), duplicates, >8, unknown; legacy `PUT /outputs/current` replaces set with `[id]`; `GET /status` returns both `output` and `outputs` |
| `AppStateTests` (new) | Persistence migration: legacy key → new key; discovery update triggers `.offline` and auto-retry |
| Manual | Settings multi-select, max-8 disable, Retry button, status badges; menu bar summary row (0/1/N cases) |

Anchors:

```
swift test --filter SelectedDevice
swift test --filter PlaybackEngine
swift test --filter APIRoutes
swift test --filter AppState
```

## Migration & rollout

- Old `PUT /outputs/current` callers keep working with no change.
- Old `GET /outputs/current` callers keep working.
- `GET /status.output` still present (mirrors first selected) — removal deferred
  to a future sub-project with a CHANGELOG note.
- UserDefaults migration is one-way (legacy single-ID key consumed and cleared
  on first run). Rollback support is not planned: downgrading the app after
  upgrade loses the multi-device selection.

## Out of scope (explicitly deferred)

- Actual audio streaming (RTSP/RTP/AEAD/decode) — sub-projects B, C, D, E.
- Synchronized multi-device playback — sub-project F.
- Drag-to-reorder selected devices in Settings.
- Per-device volume control.
- Stereo L/R pairing.
- Device groups / presets / scenes.
- Auth policy change: `/outputs/selected` follows the same bearer-token
  middleware as existing endpoints.

## Open questions

None at spec time. If something surfaces during planning or implementation,
bring it back here.
