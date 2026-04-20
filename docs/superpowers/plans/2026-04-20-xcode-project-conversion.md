# Xcode Project Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert AirBridge from SPM executable to Xcode project with App Sandbox for Mac App Store distribution.

**Architecture:** XcodeGen generates `.xcodeproj` from a declarative `project.yml`. SPM dependencies are managed via Xcode's built-in SPM integration. App Sandbox is enabled with network server/client entitlements. File staging moves from `~/.airbridge/queue/` to sandboxed Application Support.

**Tech Stack:** XcodeGen, Xcode 15+, Swift 5.10, macOS 14+

**Spec:** `docs/superpowers/specs/2026-04-20-xcode-project-conversion-design.md`

---

### Task 1: Create Asset Catalog

**Files:**
- Create: `Resources/Assets.xcassets/Contents.json`
- Create: `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `Resources/Assets.xcassets/AccentColor.colorset/Contents.json`

- [ ] **Step 1: Create asset catalog root**

```bash
mkdir -p Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p Resources/Assets.xcassets/AccentColor.colorset
```

- [ ] **Step 2: Write catalog Contents.json**

Create `Resources/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3: Write AppIcon Contents.json**

Create `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:

```json
{
  "images" : [
    {
      "idiom" : "mac",
      "platform" : "macos",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "idiom" : "mac",
      "platform" : "macos",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "idiom" : "mac",
      "platform" : "macos",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "idiom" : "mac",
      "platform" : "macos",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "idiom" : "mac",
      "platform" : "macos",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "idiom" : "mac",
      "platform" : "macos",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "idiom" : "mac",
      "platform" : "macos",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "idiom" : "mac",
      "platform" : "macos",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "idiom" : "mac",
      "platform" : "macos",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "idiom" : "mac",
      "platform" : "macos",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 4: Write AccentColor Contents.json**

Create `Resources/Assets.xcassets/AccentColor.colorset/Contents.json`:

```json
{
  "colors" : [
    {
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 5: Commit**

```bash
git add Resources/Assets.xcassets/
git commit -m "feat: add asset catalog with AppIcon and AccentColor placeholders"
```

---

### Task 2: Create Entitlements File

**Files:**
- Create: `AirBridge.entitlements`

- [ ] **Step 1: Write entitlements file**

Create `AirBridge.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Commit**

```bash
git add AirBridge.entitlements
git commit -m "feat: add App Sandbox entitlements with network server/client"
```

---

### Task 3: Update Info.plist

**Files:**
- Modify: `Resources/Info.plist`

- [ ] **Step 1: Update Info.plist with App Store and Bonjour keys**

Replace the entire `Resources/Info.plist` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AirBridge</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBonjourServices</key>
    <array>
        <string>_airplay._tcp</string>
        <string>_raop._tcp</string>
        <string>_air-bridge._tcp</string>
    </array>
    <key>NSLocalNetworkUsageDescription</key>
    <string>AirBridge discovers AirPlay devices on your local network to stream audio.</string>
</dict>
</plist>
```

Key changes from the original:
- `CFBundleIdentifier` now uses `$(PRODUCT_BUNDLE_IDENTIFIER)` build variable
- `CFBundleVersion` and `CFBundleShortVersionString` use build variables
- Added `CFBundlePackageType`, `CFBundleExecutable`
- Added `NSBonjourServices` array with the three service types
- Added `NSLocalNetworkUsageDescription`

- [ ] **Step 2: Commit**

```bash
git add Resources/Info.plist
git commit -m "feat: update Info.plist with Bonjour services and sandbox-compatible build vars"
```

---

### Task 4: Migrate FileStaging to Sandboxed Path

**Files:**
- Modify: `Sources/AirBridge/Util/FileStaging.swift`

- [ ] **Step 1: Update the `directory` computed property**

In `Sources/AirBridge/Util/FileStaging.swift`, replace:

```swift
static var directory: URL {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".airbridge")
        .appendingPathComponent("queue")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
```

with:

```swift
static var directory: URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("AirBridge")
        .appendingPathComponent("queue")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
```

Under sandbox, this resolves to `~/Library/Containers/com.gsmlg.airbridge/Data/Library/Application Support/AirBridge/queue/`. Outside sandbox (e.g., tests), it resolves to `~/Library/Application Support/AirBridge/queue/`.

- [ ] **Step 2: Run existing tests to verify nothing breaks**

Run: `swift test --filter FileStaging`

Expected: All 5 tests pass. The tests use the actual `FileStaging.directory` which now points to Application Support, but the test behavior (stage, remove, clearAll) is path-agnostic.

- [ ] **Step 3: Commit**

```bash
git add Sources/AirBridge/Util/FileStaging.swift
git commit -m "feat: migrate FileStaging to sandboxed Application Support directory"
```

---

### Task 5: Create XcodeGen project.yml

**Files:**
- Create: `project.yml`

- [ ] **Step 1: Write project.yml**

Create `project.yml`:

```yaml
name: AirBridge
options:
  bundleIdPrefix: com.gsmlg
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true

settings:
  base:
    SWIFT_VERSION: "5.10"
    MACOSX_DEPLOYMENT_TARGET: "14.0"

packages:
  Hummingbird:
    url: https://github.com/hummingbird-project/hummingbird.git
    from: "2.0.0"
  MultipartKit:
    url: https://github.com/vapor/multipart-kit.git
    from: "4.7.0"
  SRP:
    url: https://github.com/adam-fowler/swift-srp.git
    from: "2.2.0"

targets:
  AirBridge:
    type: application
    platform: macOS
    sources:
      - Sources/AirBridge
    resources:
      - Resources
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.gsmlg.airbridge
        MARKETING_VERSION: "1.0.0"
        CURRENT_PROJECT_VERSION: "1"
        INFOPLIST_FILE: Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: AirBridge.entitlements
        CODE_SIGN_STYLE: Automatic
        GENERATE_INFOPLIST_FILE: false
        ENABLE_HARDENED_RUNTIME: true
        COMBINE_HIDPI_IMAGES: true
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
    dependencies:
      - package: Hummingbird
        product: Hummingbird
      - package: MultipartKit
      - package: SRP

  AirBridgeTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Tests/AirBridgeTests
    dependencies:
      - target: AirBridge
      - package: Hummingbird
        product: HummingbirdTesting
```

- [ ] **Step 2: Commit**

```bash
git add project.yml
git commit -m "feat: add XcodeGen project.yml for Xcode project generation"
```

---

### Task 6: Remove SPM Files

**Files:**
- Remove: `Package.swift`
- Remove: `Package.resolved`

- [ ] **Step 1: Delete SPM files**

```bash
rm Package.swift Package.resolved
```

- [ ] **Step 2: Update .gitignore**

In `.gitignore`, remove the `.swiftpm/` line (no longer relevant) and ensure `*.xcodeproj/` stays. The final `.gitignore`:

```
.build/
Package.resolved
*.xcodeproj/
xcuserdata/
DerivedData/
.DS_Store
```

Note: Keep `.build/` for now since `swift test` may still be used during transition. Remove `Package.resolved` line since the file no longer exists and Xcode manages its own resolution in the xcodeproj.

Actually, the `.gitignore` should be:

```
.build/
*.xcodeproj/
xcuserdata/
DerivedData/
.DS_Store
```

Remove both `.swiftpm/` and `Package.resolved` lines.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove Package.swift and Package.resolved, clean up .gitignore"
```

---

### Task 7: Generate and Verify Xcode Project

**Files:**
- Generated: `AirBridge.xcodeproj/` (gitignored)

- [ ] **Step 1: Install XcodeGen if not present**

```bash
which xcodegen || brew install xcodegen
```

- [ ] **Step 2: Generate the Xcode project**

```bash
cd /Users/gao/Workspace/gsmlg-app/air-bridge
xcodegen generate
```

Expected output:
```
⚙️  Generating plists...
⚙️  Generating project...
⚙️  Writing project...
Created project at /Users/gao/Workspace/gsmlg-app/air-bridge/AirBridge.xcodeproj
```

- [ ] **Step 3: Build from command line**

```bash
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge -configuration Debug build 2>&1 | tail -5
```

Expected: Build succeeds (`** BUILD SUCCEEDED **`).

If there are signing issues (no team selected), that's expected — the team gets selected in Xcode interactively. The build should still succeed for Debug with `CODE_SIGN_IDENTITY=-` override:

```bash
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge -configuration Debug CODE_SIGN_IDENTITY=- build 2>&1 | tail -5
```

- [ ] **Step 4: Run tests from command line**

```bash
xcodebuild -project AirBridge.xcodeproj -scheme AirBridgeTests -configuration Debug CODE_SIGN_IDENTITY=- test 2>&1 | tail -10
```

Expected: All tests pass (`** TEST SUCCEEDED **`). If `TEST_HOST` causes issues with the unit test bundle loading, this will be debugged and fixed.

- [ ] **Step 5: Commit (no files — xcodeproj is gitignored)**

No commit needed. The generated `.xcodeproj/` is in `.gitignore`.

---

### Task 8: Update CLAUDE.md Build Instructions

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Build & Test section**

In `CLAUDE.md`, replace the `## Build & Test` section with:

````markdown
## Build & Test

```bash
# Install XcodeGen (one-time)
brew install xcodegen

# Generate Xcode project (run after any project.yml change)
xcodegen generate

# Build (command line)
xcodebuild -project AirBridge.xcodeproj -scheme AirBridge -configuration Debug build

# Build in Xcode
open AirBridge.xcodeproj

# Run tests
xcodebuild -project AirBridge.xcodeproj -scheme AirBridgeTests test

# Run the app
open .build/Build/Products/Debug/AirBridge.app
# or just press Cmd+R in Xcode
```
````

Keep the manual API testing section unchanged.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update build instructions for Xcode project"
```

---

### Task 9: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update build instructions in README**

Read `README.md` to find the current build section, then update it to reference XcodeGen and Xcode instead of `swift build`. Add a note about App Store distribution readiness.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README for Xcode project and App Store distribution"
```
