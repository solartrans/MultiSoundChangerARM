# Architecture deep-dive

Companion to `CLAUDE.md`. Focus on subsystems that have nuance — the load-bearing, audit-scrutinized parts of the codebase.

## Audio subsystem

Two files. `Audio.swift` is the CoreAudio HAL wrapper; `AudioManager.swift` is the app-facing façade that adds user-intent semantics (mute state, aggregate-device awareness, debouncing).

### `AudioImpl` (in `MultiSoundChanger/Sources/Frameworks/Audio.swift`)

Every call into CoreAudio goes through the file-private `check(_ status:_ op:)` helper which:

1. Returns `true` on `noErr`, `false` otherwise.
2. Logs non-success via `Logger.warning(...)` with the op label + numeric status code.
3. Rate-limits duplicates using a 2-second cooldown keyed by `(op, status)`. A `lastLoggedTimes` dictionary is capped at 64 entries so a flapping device can't grow it unbounded. The cap clears-then-inserts on overflow — losing cooldown memory briefly is acceptable; unbounded growth is not.
4. Serializes the cooldown dictionary via a dedicated `Self.logQueue = DispatchQueue(label: "…")` (default serial).

`kAudioPropertyElement` is a file-scope `AudioObjectPropertyElement = 0` constant. This is both `kAudioObjectPropertyElementMain` (macOS 12+) and `kAudioObjectPropertyElementMaster` (deprecated since 12). The literal dodges the deprecation warning while preserving the runtime value. Don't try to use `#available` here — the fallback branch would still reference the deprecated symbol and re-produce the warning.

HAL property writes (`setDeviceVolume`, `getDeviceVolume`) use `MemoryLayout<Float32>.size` directly instead of a preceding `AudioObjectGetPropertyDataSize` probe — halved the IPC round-trips per volume event. The scalar is always a 32-bit float per Apple's HAL contract; don't reintroduce the probe.

### Listener lifecycle (in an `extension AudioImpl` in the same file)

`AudioListenerToken` is a `final class` with three `let` fields: `objectID`, `address`, `block`. All three must be immutable — the HAL matches the exact `(address, block)` pair that was registered when `removeListener` is called. A `var address` would let a future caller accidentally mutate it and silently orphan the HAL registration.

`removeListener` copies the immutable `address` into a local `var` for the `inout` call to `AudioObjectRemovePropertyListenerBlock`. CoreAudio reads the struct fields; it doesn't need write access.

`addHardwareListener` returns `AudioListenerToken?`. On HAL failure it returns `nil` — callers must `if let token = …` and skip appending. Returning a sentinel token that was never registered would cause `deinit` to call `removeListener` on a block the HAL doesn't know about.

Blocks run on a dedicated serial `listenerQueue`. Inside the block we immediately `DispatchQueue.main.async { onChange() }` — every subsequent handler touch (menu mutation, delegate calls) must be main-thread.

### `AudioManagerImpl` (in `MultiSoundChanger/Sources/Classes/AudioManager.swift`)

Holds per-selected-device state: `selectedDevice: AudioDeviceID?`, `volumeBeforeMute: Float?`, `listenerTokens: [AudioListenerToken]`, and the debounce pair `pendingTargetVolume: Float?` + `pendingApplyItem: DispatchWorkItem?`.

`init()`:

- Enumerates `devices` from the HAL.
- Seeds `selectedDevice` from `audio.getDefaultOutputDevice()` **only if** the returned ID isn't `kAudioDeviceUnknown`. On HAL failure `selectedDevice` stays `nil`; hotkeys early-return cleanly instead of trying to write to device 0.
- Calls `registerListeners` to attach `kAudioHardwarePropertyDevices` and `kAudioHardwarePropertyDefaultOutputDevice` listeners. Each returns an optional token; only non-nil ones are appended.

`deinit`:

- Cancels `pendingApplyItem` first (no late HAL write trying to fire against a half-torn-down manager).
- Removes all listener tokens.

`selectDevice(deviceID:)` vs `adoptSelectedDevice(deviceID:)`:

- **`selectDevice`** is user-initiated. Updates `selectedDevice`, calls `audio.setOutputDevice(...)` to propagate to the system default. Only path that mutates the system's selected output.
- **`adoptSelectedDevice`** is system-initiated (the app *following* an external default-output change, or startup-matching the current default). Updates `selectedDevice` only — does NOT call `setOutputDevice`.

This split exists because `syncDefaultOutputDevice` (the delegate callback when the system default changes) would otherwise write the new default back to the system, which might refire the default-output listener and loop. `populateDeviceList` also uses `adoptDevice` for the same reason at startup.

Both paths invalidate any pending volume apply via `cancelPendingVolumeApply` — a queued write against the previous device must not land on the new one.

### Volume debounce

`setSelectedDeviceVolume(volume:)` doesn't write to the HAL synchronously. It:

1. Stores `volume` in `pendingTargetVolume`.
2. Cancels any previously-scheduled `pendingApplyItem`.
3. Schedules a fresh `DispatchWorkItem` via `DispatchQueue.main.asyncAfter(deadline: .now() + 1.0/30.0)`.

Rapid callers (hotkey repeat, slider drag) each overwrite `pendingTargetVolume` and cancel-and-reschedule. Only the final value actually round-trips to CoreAudio, 33 ms after the burst settles. `onMediaKeyTap` and the slider's `volumeSliderAction` both benefit.

**`getSelectedDeviceVolume()` returns `pendingTargetVolume` first, falls back to a live HAL read.** This is critical for correctness: without it, the quantize-against-current step at the top of `onMediaKeyTap` would read the stale HAL value three times during rapid up-up-up and compute the same next step each time, collapsing three keypresses into one visible step.

`readDeviceVolumeFromHAL()` is the uncached fallback — used by `toggleMute`'s "did the driver zero the scalar?" probe so it sees the actual device state, not user-intent.

### `toggleMute` semantics

`toggleMute` must:

1. Cancel `pendingApplyItem` first, so a queued volume write can't fire after the mute flag is set and overwrite it via `setSelectedDeviceVolume`'s auto-mute branch.
2. Save the pre-mute volume (`intendedVolume = getSelectedDeviceVolume()`, which prefers pending) so on unmute we can restore if the driver zeroed the scalar during mute.
3. On unmute: if both `volumeBeforeMute >= lowerbound` AND post-unmute HAL reads `< lowerbound`, restore via `applyVolumeToHAL(pre)`. The `pre >= lowerbound` guard prevents an auto-mute loop when the user deliberately muted silence (volume was 0 before muting).

### Aggregate devices — asymmetric read/write

`audio.isAggregateDevice(deviceID:)` → `audio.getAggregateDeviceSubDeviceList(deviceID:)` returns all sub-devices.

- **Writes** (`setSelectedDeviceVolume`, `setSelectedDeviceMute`): iterate every sub-device. Fan-out.
- **Reads** (`getSelectedDeviceVolume`, `isSelectedDeviceMuted`): return the first output sub-device's value. Read-one-sub-device.

This mirrors how the app's physical model sees aggregates: "all sub-devices go up together, representative state from the first". Don't change this without understanding why — it's been raised multiple times in audits as asymmetric and each time confirmed as intentional.

### Device-list refresh on hot-plug

`handleDevicesChanged` is the delegate callback when the HAL's device list changes (USB DAC plugged/unplugged, aggregate created, etc.). It:

1. Refreshes `devices` from the HAL.
2. If `selectedDevice` was removed from the new list, cancels any pending volume apply then reassigns to `audio.getDefaultOutputDevice()` (still guarded against `kAudioDeviceUnknown`).
3. Calls `delegate?.audioManagerDidChangeDevices(self)` so `ApplicationControllerImp` triggers `StatusBarController.refreshDeviceList()`.

## OSD subsystem

`MultiSoundChanger/Sources/Frameworks/NativeOSDManager.swift`.

### Why it exists

The original app linked Apple's private `OSD.framework` — x86_64-only, which blocked ARM64. We replaced it with a pure-Swift reimplementation that exposes an `@objc class OSDManager` with `sharedManager()` / `showImage(...)` matching the original framework's API. `MediaManager.showOSD` calls `OSDManager.sharedManager()` as if the framework still exists — **do not rename `OSDManager` or change `showImage`'s signature without updating `MediaManager.showOSD` in lockstep**.

The on-disk `OSD.framework/` directory was a leftover, removed in an earlier commit. Don't re-add it; `project.pbxproj` and the bridging header no longer reference it.

### Window reuse + fade

`OSDWindow` is instantiated once per app lifetime. `showImage` either reuses the existing window or creates a fresh one if `osdWindow` is nil. The window's content is updated in place (`update(graphic:filledChiclets:totalChiclets:screen:)`) — don't recreate per event, that was the source of several crash-fix commits before the current design.

Fade-out uses `NSAnimationContext.runAnimationGroup` with an explicit `completionHandler` that calls `orderOut`. Don't revert to the old raw `animator().alphaValue = 0` + `DispatchQueue.main.asyncAfter(0.3)` pattern — the two timelines could race and `orderOut` could land before the fade completed.

`isReleasedWhenClosed = false` is deliberate — the window is reused across events, not closed. We never call `close()`, only `orderOut`.

### Threading

`sharedManager()` returns a `static let instance` — thread-safe initialization via Swift's static-let dispatch_once semantics, no manual locking.

`showImage` branches on `Thread.isMainThread`. If already on main (the volume-hotkey path always is), it calls `displayOSD` synchronously — skipping the runloop hop saves a visible frame between keypress and OSD appearance. If called from a non-main context, it falls back to `DispatchQueue.main.async`. All access to `osdWindow` happens on main after this branch, so no explicit lock is needed.

### Positioning

`repositionOn(screen:)` uses `screen.visibleFrame` (not `screen.frame`) so the OSD respects the menu bar and dock on the primary display. Placement is `midY + height/4 - windowHeight/2` — intentionally above the screen's vertical center. Audit agents have flagged this as a sign error; it's not.

### Enum

`OSDGraphic` only has `.speaker` and `.speakerMuted`. The original framework's `.backlight`, `.eject`, `.noWiFi`, `.keyboardBacklightMeter`, `.macProOpen`, `.hotspot`, `.sleep` cases were dead code in our app and removed.

## Media-key pipeline

`MultiSoundChanger/Sources/Classes/MediaManager.swift`.

### Registration

`listenMediaKeyTaps()` is called once from `ApplicationControllerImp.start()`. It does three things:

1. `observeMediaKeyOnAccessibilityApiChange()` — subscribes to `DistributedNotificationCenter`'s `com.apple.accessibility.api` so permission toggles re-register the tap without relaunch.
2. `acquirePrivileges()` — `AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt: true)`. This prompts the user to grant Accessibility access. Called exactly **once** per process; don't move it back into `startMediaKeyTap` where it would re-prompt every time the accessibility notification fires.
3. `startMediaKeyTap()` — creates a `MediaKeyTap` instance for `[.volumeUp, .volumeDown, .mute]` with `observeBuiltIn: true` and starts it. Safe to call multiple times (stops the previous tap first).

### Accessibility notification debounce

`DistributedNotificationCenter` is a shared OS bus — **any local process can post** `com.apple.accessibility.api`. Without throttling, a hostile process could flood us and force CGEventTap to recreate itself in a loop (DoS — no code-exec, but CPU burn and event-tap exhaustion).

`onAccessibilityNotification` uses a 500 ms trailing-edge debounce via `accessibilityNotificationWork: DispatchWorkItem?` — cancels the previous work item, schedules fresh. Legitimate single toggles still fire one restart; a flood collapses to one restart 500 ms after the last spoofed post.

`deinit` cancels `accessibilityNotificationWork` before removing the observer, symmetric with `AudioManagerImpl.deinit` cancelling `pendingApplyItem`.

### Event routing

```
MediaKeyTap (CGEventTap, DispatchQueue.main.sync delivery from fork)
  → MediaManagerImpl.handle(mediaKey:event:modifiers:)           [main]
  → delegate?.onMediaKeyTap(mediaKey:)                           [main]
  → ApplicationControllerImp.onMediaKeyTap(mediaKey:)            [main]
    → paint UI (OSD + slider + icon) via paintVolumeFeedback(_:)
    → audioManager.setSelectedDeviceVolume(volume:)  [volumeUp/Down]
      OR audioManager.toggleMute()                   [.mute]
```

**UI paint precedes the HAL write for volumeUp/volumeDown.** This is deliberate. The HAL write is debounced + asynchronously applied; painting first makes the OSD and slider appear on the user's frame of the keypress, not after the CoreAudio round-trip. For `.mute`, the HAL write stays first because the OSD glyph depends on the post-toggle mute state.

## Status bar / menu UI

`MultiSoundChanger/Sources/Classes/StatusBarController.swift`.

### `NSMenuDelegate` and deferred refresh

`StatusBarControllerImpl` inherits from `NSObject` (required for `NSMenuDelegate` conformance) and implements:

- `menuWillOpen(_:)` → sets `isMenuOpen = true`.
- `menuDidClose(_:)` → sets `isMenuOpen = false` and runs any `pendingRefresh` work.

`refreshDeviceList()` is called from the `AudioManagerDelegate` path when the HAL reports a device topology change. If the menu is currently open, mutating NSMenu's items can crash AppKit's tracking machinery — so the method sets `pendingRefresh = true` and returns. `menuDidClose` drains the pending flag. This pattern exists because the alternative (always mutate, hope) used to crash on fast USB device hot-plug during an open menu.

### Device-list reconstruction

Device items are tracked in `deviceMenuItems: [NSMenuItem]` and anchored at `outputSectionAnchor: NSMenuItem?` (the disabled "Output Device:" label). `populateDeviceList(in:)`:

- Sorts the devices dictionary by name (case-insensitive localized compare) — without this, dictionary iteration order is unspecified and the menu would reshuffle per launch.
- Inserts each device item at `anchorIndex + 1`. If the anchor is missing (shouldn't be, but defensive), logs a warning and returns — better to have a stale menu than items appended after the Quit item.

### `selectDevice(device:)` vs `adoptDevice(_:)` (mirrors AudioManager)

- `selectDevice` is used by `menuItemAction` (user clicked a row in the device menu). Propagates to the system default.
- `adoptDevice` is used by `populateDeviceList` (startup match to system default) and `syncDefaultOutputDevice` (external default-change notification). Does NOT propagate — would cause a listener loop.

Both share `refreshUIForSelectedDevice()` which pulls the current volume, applies mute correction, and updates the slider + status-bar icon.

### Status-bar icon bucketing

`changeStatusItemImage(value:)` maps 0–100 → one of four icons at thresholds `<=1`, `<=33.33`, `<=66.66`, `else`. The `<=1` edge case is deliberate — `value == 1` (exactly 1%) used to fall into no bucket in the old `< 1 / > 1` form, leaving the icon stale. `100 / 3 * 2` evaluates to `(100/3)*2 ≈ 66.66`. Do not "correct" to `100/(3*2) = 16.67` — that would be wrong.

## Logger

`MultiSoundChanger/Sources/Utils/Logger.swift`.

### File write path

`Logger.debug/info/warning/error` → `outAndFilePrint(symbol:string:)`:

1. **Synchronously** `print()` to stdout on the caller's thread (cheap).
2. **Async** on `fileWriteQueue` (serial background) → `filePrint` → `appendToFile`.

Main thread is never blocked on FileManager or FileHandle syscalls. Before this refactor, every volume-hotkey press synchronously wrote to disk from `ApplicationControllerImp.onMediaKeyTap`, stuttering rapid key-repeat.

### POSIX write with `O_NOFOLLOW`

`appendToFile(url:content:)` opens via raw `Darwin.open(path, O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW, 0o600)` — not `FileHandle(forWritingTo:)`. The reason is symlink defense: a local attacker planting a symlink at `~/Library/Caches/<bundleID>/app.log` pointing to e.g. `~/.ssh/id_rsa` would otherwise cause our append to flow through the symlink and corrupt the target. `O_NOFOLLOW` makes `open()` return `ELOOP` if the final path component is a symlink.

Creation mode `0o600` keeps the log file user-only regardless of the process's umask.

`defer { Darwin.close(fd) }` on every success path — `write` errors don't leak the descriptor.

### Write loop

`Darwin.write` can return fewer bytes than requested on `EINTR`, signal interruption, or disk pressure. The loop:

- Advances `offset` by the returned count on success.
- `continue`s on `errno == EINTR`.
- Breaks on `written == 0` (unusual but not strictly an error; abort).
- Escalates other errno values to a thrown `LoggerError.fileError(...)`.

### `LoggerError` conforms to `LocalizedError`

`filePrint` catches errors and surfaces them via `error.localizedDescription`. Without `LocalizedError` conformance, `localizedDescription` returns Cocoa's generic `"The operation couldn't be completed."` wrapper — and our carefully-constructed `"open(/path) failed: <strerror> (errno=N)"` telemetry is replaced with a useless string. `errorDescription` on the enum returns the actual message.

### `isLogFileRemoved` serialization

Declared `private static var`. Access is NOT lock-guarded, **and that's fine** — every read/write happens inside the `fileWriteQueue.async` block, and that queue is serial (DispatchQueue with no attributes). This has been flagged as a race in multiple audits; each time the answer is "trace the call sites, they're all on the serial queue". The comment above the declaration spells this out.

### `DateFormatter` cached

`logDateFormatter: DateFormatter` is a `static let`, constructed once and reused. DateFormatter construction is orders of magnitude more expensive than `.string(from:)`; per-log-call construction was measurable. Apple documents DateFormatter as thread-safe for read use post-init, and `fileWriteQueue` serializes our access anyway.

## Application lifecycle

`AppDelegate.applicationDidFinishLaunching(_:)` calls `applicationController.start()`, which:

1. `audioManager.delegate = self` — wired FIRST so any HAL listener callback queued during `AudioManagerImpl`'s construction finds a non-nil delegate when its main-queue continuation runs.
2. `statusBarController.createMenu()` — constructs the status item + menu, including the initial device list.
3. `mediaManager.listenMediaKeyTaps()` — registers the DistributedNotificationCenter observer, prompts Accessibility, starts the CGEventTap.

Order matters. Don't rearrange.

`ApplicationControllerImp` conforms to both `MediaManagerDelegate` (for `onMediaKeyTap`) and `AudioManagerDelegate` (for `audioManagerDidChangeDevices` / `audioManagerDidChangeDefaultOutputDevice`). Both delegates are declared `weak` on their managers — no retain cycles.

## `AudioManager` + `StatusBarController` + debouncer interaction summary

```
   Volume hotkey or slider drag
         │
         ▼
   paintVolumeFeedback(_:)              ← slider + icon + OSD appear INSTANTLY
         │
         ▼
   audioManager.setSelectedDeviceVolume(volume:)
         │ (stores pendingTargetVolume, schedules DispatchWorkItem +33ms)
         ▼
   [33 ms trailing-edge fire on main]
         │
         ▼
   applyVolumeToHAL(_:)                 ← actual CoreAudio IPC (fan-out on aggregate)

   Subsequent getSelectedDeviceVolume() calls return pendingTargetVolume
   until the work item fires, then fall back to a live HAL read.

   toggleMute / selectDevice / adoptSelectedDevice / handleDevicesChanged
   ALL call cancelPendingVolumeApply() first to prevent a queued write
   from landing on wrong state.
```

This architecture is what makes rapid volume keys feel instant while also keeping the HAL in sync with user intent eventually. Preserve it.
