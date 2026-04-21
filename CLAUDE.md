# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

MultiSoundChanger is a macOS menu-bar utility that adjusts output volume — including on **aggregate devices**, which macOS's own volume controller cannot handle. This repo is the ARM64-migrated fork (universal binary; Intel + Apple Silicon). Deployment target: macOS 11.0. See `ARM64_MIGRATION.md` for the full migration history.

## Build / Run

**Always open `MultiSoundChanger.xcworkspace`, not `MultiSoundChanger.xcodeproj`.** The app depends on CocoaPods (SwiftLint, MediaKeyTap), so building through the `.xcodeproj` directly will fail.

```bash
pod install                                # first-time or after Podfile changes
open MultiSoundChanger.xcworkspace         # then ⌘B / ⌘R in Xcode
```

Command-line build (universal):
```bash
xcodebuild -workspace MultiSoundChanger.xcworkspace \
           -scheme MultiSoundChanger -configuration Release \
           -arch "x86_64 arm64" clean build
```

Lint: SwiftLint runs as a build phase (configured by `.swiftlint.yml`, which uses an explicit `whitelist_rules` allowlist rather than the default rule set). `Pods/` is excluded.

There is no test target.

## Architecture

The app is a status-bar-only Cocoa app (no main window). Entry point → dependency graph:

```
AppDelegate
  └── ApplicationController  (owns the three managers, wires MediaKeyTap → audio)
        ├── AudioManager      — selected-device state, mute, volume
        │     └── Audio       — CoreAudio HAL wrapper (AudioObjectGet/SetPropertyData)
        ├── MediaManager      — MediaKeyTap delegate + OSD display + accessibility prompts
        └── StatusBarController — NSStatusItem menu, device list, VolumeViewController
              └── VolumeViewController (Volume.storyboard)
```

Every class is defined as `protocol Foo` + `final class FooImpl` and injected by its parent. Stick to that pattern when adding components.

### Aggregate-device handling (the core feature)

`AudioManagerImpl` checks `audio.isAggregateDevice(deviceID:)` on every volume/mute operation. For aggregates it fans out: `getAggregateDeviceSubDeviceList` → iterate → apply `setDeviceVolume` / `setDeviceMute` to each sub-device. The *getter* path is asymmetric — it returns `audio.getDeviceVolume(…).max()` from the first output sub-device rather than aggregating. Preserve this fan-out-on-write / read-one-sub-device model when touching `AudioManager` or `Audio.swift`.

### OSD (ARM64-critical)

The original app linked `OSD.framework` (private Apple framework, x86_64-only), which blocked ARM64. It was replaced by `Sources/Frameworks/NativeOSDManager.swift`, a pure-Swift reimplementation exposing an `@objc` class **named `OSDManager`** with a `sharedManager()` / `showImage(...)` API that matches the original framework's signature. `MediaManager` calls this as if the framework still exists — do not rename `OSDManager` or change its method shape without also updating `MediaManager.showOSD`.

The on-disk `OSD.framework/` directory is a leftover and is no longer referenced by `project.pbxproj`; do not re-add it. The bridging header (`MultiSoundChanger-Bridging-Header.h`) likewise no longer imports it.

### MediaKey flow

`MediaManagerImpl` uses a custom fork of MediaKeyTap (pinned in `Podfile` to `the0neyouseek/MediaKeyTap` master). It requires Accessibility permission; the app prompts via `AXIsProcessTrustedWithOptions` on startup and re-calls `startMediaKeyTap()` when it observes `com.apple.accessibility.api` DistributedNotification (so permission changes take effect without relaunch). Key events route: MediaKeyTap → `MediaManagerDelegate` → `ApplicationControllerImp.onMediaKeyTap` → `AudioManager` + `StatusBarController.updateVolume` + `MediaManager.showOSD`.

Volume is quantized to `Constants.chicletsCount` (16) steps so hardware key presses align with OSD chiclets.

## Workflow

- **Active branch**: `claude/rebuild-x86-app-011CV4gXVczxQsxNuHeA9X9o` (targets PR #39 on `rlxone/MultiSoundChanger`).
- **After every round of changes, commit and push to that branch.** Don't batch rounds locally — push after each cohesive commit or group of commits so the PR reflects progress and the reviewer sees the evolving state. The push target is `origin` (`solartrans/MultiSoundChangerARM`); the PR against upstream (`rlxone/MultiSoundChanger`) updates automatically.
- If `git push` fails from a non-interactive shell (no cached credential, no SSH key in `~/.ssh`), ask the user to run it themselves via the `! git push origin claude/rebuild-x86-app-011CV4gXVczxQsxNuHeA9X9o` escape-hatch in the prompt rather than skipping the push. Never silently leave commits unpushed.

## Conventions

- Swift-only source lives under `MultiSoundChanger/Sources/`; non-code assets and `Constants.swift` under `MultiSoundChanger/Other/`.
- UI is storyboard-based (`Volume.storyboard`, `Main.storyboard`). View controllers are loaded via the `Stories` enum helper, which instantiates by `String(describing: classType)` — so storyboard identifiers **must match the class name exactly**.
- All user-visible strings go through `Strings.*` (see `Other/Localization/`); log/debug strings go through `Constants.InnerMessages`.
- Logging: use `Logger.debug / info / warning / error`. The logger writes to `app.log` in addition to stdout.
