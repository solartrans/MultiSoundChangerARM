# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

For deep-dive subsystem docs, see `docs/`:

- **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** — subsystem-by-subsystem design: audio HAL wrapper, aggregate device model, debounce pipeline, OSD window, media-key flow, menu UI, logger. **Read this before non-trivial changes.**
- **[`docs/BUILD_AND_SIGNING.md`](docs/BUILD_AND_SIGNING.md)** — Xcode workspace, CocoaPods pinning, Hardened Runtime, entitlements file, distribution posture.
- **[`docs/AUDIT_NOTES.md`](docs/AUDIT_NOTES.md)** — things audit agents keep misflagging as bugs but aren't. **Read this before proposing "fixes" to flagged patterns** — the list exists because each item was raised, triaged, and documented as intentional.

## Project

MultiSoundChanger is a macOS menu-bar utility that adjusts output volume — including on **aggregate devices**, which macOS's own volume controller cannot handle. This repo is the ARM64-migrated fork (universal binary; Intel + Apple Silicon). Deployment target: macOS 11.0. See `ARM64_MIGRATION.md` for the full migration history.

## Build / Run

**Always open `MultiSoundChanger.xcworkspace`, not `MultiSoundChanger.xcodeproj`.** The app depends on CocoaPods (SwiftLint, MediaKeyTap), so building through the `.xcodeproj` directly will fail.

```bash
pod install                                # first-time or after Podfile changes
open MultiSoundChanger.xcworkspace         # then ⌘B / ⌘R in Xcode
```

Command-line universal build:

```bash
xcodebuild -workspace MultiSoundChanger.xcworkspace \
           -scheme MultiSoundChanger -configuration Release \
           -arch "x86_64 arm64" clean build
```

On this user's machine `xcodebuild` is broken (unrelated `IDESimulatorFoundation` plugin issue). For automated verification use Swift typecheck instead — see `docs/BUILD_AND_SIGNING.md`.

There is no test target. SwiftLint runs as a build phase (`.swiftlint.yml` uses `whitelist_rules`, not default rules; `Pods/` excluded).

## Architecture at a glance

Status-bar-only Cocoa app (no main window). Entry point → dependency graph:

```
AppDelegate
  └── ApplicationControllerImp  (owns the three managers; is AudioManagerDelegate + MediaManagerDelegate)
        ├── AudioManagerImpl        — selected-device state, debounced volume writes, mute + aggregate fan-out
        │     └── AudioImpl         — CoreAudio HAL wrapper (AudioObjectGet/SetPropertyData with OSStatus checking)
        ├── MediaManagerImpl        — MediaKeyTap delegate + OSD trigger + Accessibility permission flow
        │     └── OSDManager (inline @objc singleton in NativeOSDManager.swift)
        └── StatusBarControllerImpl — NSStatusItem menu, device list (sorted), NSMenuDelegate, VolumeViewController host
              └── VolumeViewController (loaded from Volume.storyboard)
```

Every class is defined as `protocol Foo` + `final class FooImpl` and injected by its parent. Stick to that pattern when adding components.

### Key invariants (one-liners — expanded in `docs/ARCHITECTURE.md`)

- **Aggregate devices**: writes fan out to every sub-device; reads return `.max()` from the *first* output sub-device. Intentionally asymmetric. Preserve.
- **`AudioManagerImpl.setSelectedDeviceVolume`** is debounced (33 ms trailing edge). The getter returns `pendingTargetVolume` when set so rapid-repeat quantization sees user intent, not stale HAL state.
- **OSDManager** is a thread-safe `static let` singleton. `showImage` branches on `Thread.isMainThread` to avoid an unnecessary runloop hop from the hotkey path.
- **Volume quantization**: `Constants.chicletsCount = 16` steps so hardware keys align with the OSD chiclets.
- **MediaKeyTap** is pinned by commit hash in `Podfile` (supply-chain fix — never switch back to a floating branch ref).
- **Log writes** use raw POSIX `open(O_NOFOLLOW, 0o600)` — symlink defense against `~/Library/Caches/<bundle>/app.log` being redirected at a sensitive file.
- **Hardened Runtime on** (both Debug + Release). Entitlements declare only `com.apple.security.cs.disable-library-validation` — required because CocoaPods embeds MediaKeyTap as a dynamic framework and our ad-hoc signing has no team identity for library validation to match. See `docs/BUILD_AND_SIGNING.md`.
- **Storyboard identifiers must match class names exactly** (`Stories.swift` instantiates by `String(describing:)`).

## Workflow

- **Active branch**: `claude/rebuild-x86-app-011CV4gXVczxQsxNuHeA9X9o` (targets PR #39 on `rlxone/MultiSoundChanger`).
- **After every round of changes, commit and push to that branch.** Don't batch rounds locally. Push target is `origin` (`solartrans/MultiSoundChangerARM`); the PR against upstream updates automatically.
- **Credentials**: a GitHub fine-grained PAT is stored in the macOS Keychain under `git credential-osxkeychain`. `git push` works without any additional setup. If a push ever fails with "Authentication failed", the token likely expired or lost `Contents: Read and write` permission — tell the user, don't try to work around it.
- If SSH/git tooling ever breaks in the sandboxed shell for unrelated reasons, ask the user to run `! git push origin claude/rebuild-x86-app-011CV4gXVczxQsxNuHeA9X9o` as a fallback rather than leaving commits unpushed.

## Conventions

- Swift-only source lives under `MultiSoundChanger/Sources/`; non-code assets and `Constants.swift` under `MultiSoundChanger/Other/`.
- UI is storyboard-based (`Volume.storyboard`, `Main.storyboard`). View controllers are loaded via the `Stories` enum helper, which instantiates by `String(describing: classType)` — storyboard identifiers **must match the class name exactly**.
- All user-visible strings go through `Strings.*` (see `Other/Localization/`). Log/debug strings go through `Constants.InnerMessages`.
- Logging: `Logger.debug / info / warning / error`. Writes to `~/Library/Caches/<bundleID>/app.log` via a serial background queue + raw POSIX `open(O_NOFOLLOW, 0o600)`; does NOT block main. See `docs/ARCHITECTURE.md` for the rationale.
- Device names are sanitized (newlines/tabs stripped) before logging — see `AudioManagerImpl.sanitizedForLog`. Audio HAL may return any string a plugin chose.
- `fileprivate` is preferred over `private` for same-file extension access (e.g., the listener methods extension on `AudioImpl`). Avoid leaking internal details past the file.

## What NOT to do

Collected from a long audit-fix loop; each item has been flagged multiple times by different agents and each is intentional:

- Don't "fix" `AudioManagerImpl.readDeviceVolumeFromHAL` returning `nil` on an aggregate with no output sub-device — it's documented design.
- Don't rewrite `StatusBarController`'s `100 / 3 * 2` threshold — it IS the correct two-thirds boundary (`(100/3)*2 = 66.66…`), not a precedence bug.
- Don't add an explicit lock around `Logger.isLogFileRemoved` — all access is already serialized via the `fileWriteQueue`.
- Don't switch OSD positioning from `screen.visibleFrame.midY + height/4` to lower-half; the upper-center placement is intentional.
- Don't revert the `@NSApplicationMain` to `@main` — the app's storyboard entry requires the former on this target configuration.
- Don't re-add `Runner.shell` and the `open -b` path for System Settings; the `x-apple.systempreferences:` URL via `NSWorkspace` replaced it for both subprocess-surface reduction and macOS Ventura+ compatibility.
- Full list: **[`docs/AUDIT_NOTES.md`](docs/AUDIT_NOTES.md)**.

## When in doubt

- Need to touch the audio path? Read `docs/ARCHITECTURE.md` § Audio subsystem first.
- Need to change build / signing / pods? Read `docs/BUILD_AND_SIGNING.md`.
- Have a finding from a static analyzer or audit agent and unsure if it's real? Check `docs/AUDIT_NOTES.md` — if it's listed, it's already been triaged and it's not a bug.
