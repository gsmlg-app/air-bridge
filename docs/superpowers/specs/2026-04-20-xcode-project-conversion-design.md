# AirBridge: Xcode Project Conversion for App Store Distribution

**Date:** 2026-04-20
**Status:** Approved

## Goal

Convert AirBridge from a Swift Package Manager executable to an Xcode project suitable for Mac App Store publication. Remove `Package.swift` entirely — Xcode-only build system going forward.

## Decisions

- **Build system:** Xcode-only via XcodeGen (`project.yml` → generated `.xcodeproj`)
- **Distribution:** Mac App Store with App Sandbox
- **Signing:** Automatic signing, personal team (selected in Xcode)
- **App icon:** Asset catalog with empty AppIcon placeholder

## Project Structure (After)

```
air-bridge/
├── project.yml                  # XcodeGen spec (source of truth)
├── AirBridge.xcodeproj/         # Generated, gitignored
├── AirBridge.entitlements        # Sandbox entitlements
├── Sources/AirBridge/            # Unchanged source layout
│   ├── App/
│   ├── AirPlay/
│   ├── MenuBar/
│   ├── Playback/
│   ├── Transport/
│   └── Util/
├── Tests/AirBridgeTests/         # Unchanged test layout
├── Resources/
│   ├── Info.plist                # Updated
│   └── Assets.xcassets/          # NEW
│       ├── Contents.json
│       ├── AppIcon.appiconset/
│       │   └── Contents.json
│       └── AccentColor.colorset/
│           └── Contents.json
└── ...
```

## Files Added

### 1. `project.yml` (XcodeGen Specification)

Declares:
- **App target** (`AirBridge`): macOS application, SwiftUI lifecycle, sources from `Sources/AirBridge/`, resources from `Resources/`
- **Test target** (`AirBridgeTests`): unit test bundle, sources from `Tests/AirBridgeTests/`
- **SPM dependencies**: Hummingbird 2.x, MultipartKit 4.7.x, swift-srp 2.2.x
- **Build settings**: macOS 14.0 deployment target, Swift 5.10, automatic signing

### 2. `AirBridge.entitlements`

```xml
com.apple.security.app-sandbox = true
com.apple.security.network.server = true
com.apple.security.network.client = true
```

- `network.server`: required for the Hummingbird HTTP server on localhost
- `network.client`: required for AirPlay device connections and Bonjour resolution

### 3. `Resources/Assets.xcassets/`

Standard Xcode asset catalog with:
- Empty `AppIcon.appiconset` (user adds icon later)
- Default `AccentColor.colorset`

## Files Modified

### 4. `Resources/Info.plist`

Add keys:
- `NSBonjourServices`: `["_airplay._tcp", "_raop._tcp", "_air-bridge._tcp"]`
- `NSLocalNetworkUsageDescription`: "AirBridge discovers AirPlay devices on your local network to stream audio."
- `CFBundlePackageType`: `APPL`

Keep existing:
- `LSUIElement = true`
- `CFBundleIdentifier = com.gsmlg.airbridge`
- `CFBundleVersion = 1`
- `CFBundleShortVersionString = 1.0.0`

### 5. `Sources/AirBridge/Util/FileStaging.swift`

Migrate from `~/.airbridge/queue/` to sandboxed Application Support directory:

```swift
// Before (not accessible under sandbox):
// ~/.airbridge/queue/

// After (sandbox-compatible):
// ~/Library/Containers/com.gsmlg.airbridge/Data/Library/Application Support/AirBridge/queue/
FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("AirBridge/queue")
```

### 6. `.gitignore`

Add:
- `*.xcodeproj/` (already present)
- Remove `.swiftpm/` (no longer relevant)

## Files Removed

- `Package.swift`
- `Package.resolved`

## Build & Run (After)

```bash
# Install XcodeGen (one-time)
brew install xcodegen

# Generate project
xcodegen generate

# Open in Xcode
open AirBridge.xcodeproj

# Or build from CLI
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge -configuration Debug build

# Run tests
xcodebuild -project AirBridge.xcodeproj -scheme AirBridgeTests -configuration Debug test
```

## App Store Requirements Checklist

- [x] App Sandbox enabled
- [x] Network entitlements for server + client
- [x] Bonjour services declared in Info.plist
- [x] Local network usage description
- [x] LSUIElement for menu-bar-only app
- [x] Bundle identifier set
- [x] Version and build number configured
- [x] Asset catalog with AppIcon placeholder
- [ ] App icon artwork (user provides later)
- [ ] App Store Connect listing (out of scope)
- [ ] Privacy policy URL (out of scope)

## Risks

- **Hummingbird in sandbox**: The HTTP server binds to `127.0.0.1` which works under sandbox with `network.server` entitlement. No risk.
- **Bonjour under sandbox**: Requires `NSBonjourServices` in Info.plist. Already planned.
- **App Review concerns**: Running a local HTTP server is unusual but permitted. The `NSLocalNetworkUsageDescription` explains the purpose. If Apple pushes back, the server could be made opt-in, but this is unlikely for localhost-only binding.
