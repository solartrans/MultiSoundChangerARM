# Audit notes: things that LOOK like bugs but aren't

This file exists because the codebase has been through ~15 audit passes (12 agents each) across security and general-bug sweeps. The same handful of patterns got flagged over and over — each was triaged, confirmed intentional, and the rationale captured here so future audits (and future Claude sessions) don't re-raise them.

If a static analyzer, LSP, or audit agent flags something listed here, **it's not a bug**. The fix is already in place or the code is intentionally shaped this way.

## Code patterns

### 1. `AudioManagerImpl.readDeviceVolumeFromHAL` returns `nil` on an aggregate with no output sub-device

**Flagged as**: "silent failure", "nil return breaks volume display".

**Reality**: Documented design. See `docs/ARCHITECTURE.md` § aggregate devices. An aggregate legitimately has no volume to read if none of its sub-devices are outputs — returning `nil` is honest. Callers (`getSelectedDeviceVolume`, `toggleMute`'s unmute-restore check) handle nil correctly.

### 2. `StatusBarController.changeStatusItemImage` thresholds `100 / 3 * 2`

**Flagged as**: "operator precedence bug; should be `100 / (3 * 2) = 16.67`."

**Reality**: The code is intentional. `100 / 3 * 2 = (100/3) * 2 ≈ 66.66` is the upper-third threshold for mapping volume → icon (four icons, three boundaries at 0, 33.33, 66.66, 100). The other way around would be nonsensical.

### 3. `[Float].max()` returning `Float?`

**Flagged as**: "nil-safety violation", "force-unwrap risk".

**Reality**: Correct by design. `Array.max()` returns `Element?` because an empty array has no max. `getDeviceVolume` returns a 3-element array `[master, left, right]`, so `.max()` never nil in practice, but the optional signature is Swift's stdlib behavior.

### 4. `Constants.chicletsCount = 16` "division by zero risk"

**Flagged as**: "if chicletsCount is 0, `1 / Float(Constants.chicletsCount)` crashes".

**Reality**: It's a compile-time constant literal `16`. It can't be 0 unless someone edits `Constants.swift` to make it 0. Not a runtime risk.

### 5. `CFStringCreateWithSubstring` in `Audio.getDeviceName`

**Flagged as**: "leaks the retained CFString; needs `takeRetainedValue()` or `CFRelease`".

**Reality**: `CFStringCreateWithSubstring` is annotated `CF_RETURNS_RETAINED` in CoreFoundation, and Swift's CF bridge imports it as a Swift-ARC-managed `CFString?`. It is NOT an `Unmanaged<CFString>?`. The local `truncated` var goes through standard Swift retain/release at function exit. No leak.

### 6. HAL listener `onChange` strong capture

**Flagged as**: "retain cycle — block captures onChange strongly".

**Reality**: The block DOES capture `onChange` strongly, on purpose. `onChange` is what the caller passed in, and at the call site it's `{ [weak self] in self?.handleDevicesChanged() }` — so `onChange` weakly references `self`. If `self` deallocates, the closure body becomes a no-op. No cycle.

### 7. `DispatchQueue.main.async` in the HAL listener block

**Flagged as**: "redundant main-hop; should call `onChange` directly."

**Reality**: The HAL listener fires on a dedicated background serial queue (`listenerQueue`). Every subsequent handler touches NSMenu / NSStatusItem / UI state, which must be on main. The hop is mandatory.

### 8. `OSDWindow` mutation / `osdWindow` thread safety

**Flagged as**: "race condition on `osdWindow` / `fadeTimer`".

**Reality**: `OSDManager.showImage` branches on `Thread.isMainThread`. If on main, calls `displayOSD` synchronously; if off main, hops to main via `async`. Either way, `displayOSD` and all mutations of `osdWindow` / `fadeTimer` run exclusively on main. No concurrent access.

### 9. `Logger.isLogFileRemoved` "race condition"

**Flagged as**: "static mutable flag without a lock".

**Reality**: All reads/writes of `isLogFileRemoved` happen inside `fileWriteQueue.async { try filePrint(…) } → removeLogFileIfNeeded`. `fileWriteQueue` is a `DispatchQueue(label:)` with no attributes — serial by default. A serial queue serializes every block it runs, so access is trivially sequenced. The comment at the declaration spells this out.

### 10. `IBOutlet weak var foo: NSSlider!` "force unwrap"

**Flagged as**: "force_unwrapping SwiftLint violation".

**Reality**: The `!` is an implicitly-unwrapped-optional declaration, standard Swift idiom for storyboard-wired outlets. SwiftLint's `force_unwrapping` rule targets uses like `someOptional!`, not IUO declarations.

### 11. `case empty = ""` "empty_string violation"

**Flagged as**: "`Constants.Keys.empty = ""` violates `empty_string` rule."

**Reality**: SwiftLint's `empty_string` rule targets `String()` initializer calls and `== ""` comparisons, not enum raw-value literals. The enum case's raw value is a compile-time constant string; there's nothing to flag.

### 12. OSD y-position `screen.visibleFrame.midY + height/4`

**Flagged as**: "sign error; should be `- height/4` for lower-half placement".

**Reality**: Intentionally upper-center. `midY + height/4` places the OSD ~25% above the vertical center, matching where the original `OSD.framework` drew. Lower-half placement would conflict with the dock and Command-Tab UI area.

### 13. `printDevices()` / `sanitizedForLog(_:)` in AudioManager "dead code"

**Flagged as**: "never called / serves no purpose".

**Reality**: `printDevices()` is called from `AudioManagerImpl.init()` (startup device enumeration for log). `sanitizedForLog` is called from `printDevices`. Both are live. The "only logs debug output" dismissal is wrong — logging IS the purpose.

### 14. Partial write in `Logger.appendToFile`

**Flagged as**: "single `Darwin.write` without a loop drops tail bytes on EINTR".

**Reality**: There IS a loop — lines inside `data.withUnsafeBytes { buffer -> String? in var offset = 0; while offset < buffer.count { … } }`. It retries `EINTR`, bails on `write == 0`, escalates other errno values. Don't re-flag based on a skim.

### 15. `VolumeViewController` "slider unit mismatch"

**Flagged as**: "passes 0…100 UI value to HAL's 0…1 expected range".

**Reality**: The code does `audioManager?.setSelectedDeviceVolume(volume: sliderValue / 100)`. Divides by 100. Read it.

### 16. Ad-hoc code signing "security issue"

**Flagged as**: "CODE_SIGN_IDENTITY = '-' is insecure for distribution".

**Reality**: True for distribution, false for local dev / source-built use. For shipping, switch to Developer ID — see `docs/BUILD_AND_SIGNING.md`. The app is open-source and the maintainer doesn't distribute binaries themselves; ad-hoc is the right posture here. Don't flag this as if it's a blocking issue.

### 17. `com.apple.security.cs.disable-library-validation` in entitlements "weakens security"

**Flagged as**: "Hardened Runtime exception — violates principle of least privilege".

**Reality**: Required for ad-hoc-signed apps with embedded CocoaPods frameworks. Without it, `Product → Archive → Export → double-click` fails to launch because library validation rejects the embedded MediaKeyTap.framework (ad-hoc signatures have no team identity to match). Narrow scope — affects which dylibs can load into this process only. Real risk requires write access to the .app bundle, which strictly subsumes dylib injection. Remove only when shipping via Developer ID + notarization, which makes the library validation work without exception.

### 18. "`xcuserdata/` has `DynamicsIllusion.xcscheme`"

**Flagged as**: "stale schema from pre-fork project".

**Reality**: `xcuserdata/` is user-specific Xcode state, not part of the project definition. Those schemes belong to whoever originally created the repo's Xcode state; they don't affect builds on other machines. The tracked `project.pbxproj` and `.xcscheme` files under `xcshareddata/` are the authoritative version. Don't delete `xcuserdata/` content as a "fix".

### 19. `@NSApplicationMain` "deprecated in Swift 5.3+"

**Flagged as**: "should be `@main`".

**Reality**: We tried `@main` once and it broke the build. `@main` requires the type itself to provide a `static func main()`; `@NSApplicationMain` emits an auto-generated `main()` that calls `NSApplicationMain()` which loads the Main storyboard. Our app relies on the storyboard loader, so we need `@NSApplicationMain`. Apple still supports it on macOS; the deprecation is a style warning at most.

## Tool caveats

### SourceKit single-file mode lies

The editor's LSP (SourceKit-LSP) runs in single-file parse mode without the full module graph. It will constantly report:

- `Cannot find type 'AudioManager' in scope`
- `Cannot find 'Logger' in scope`
- `Cannot find 'Constants' in scope`
- `'clamped' is inaccessible due to 'package' protection level`
- `No such module 'MediaKeyTap'`

None of these are real. Always verify with the full-project `xcrun swiftc -typecheck` command in `docs/BUILD_AND_SIGNING.md`.

### `swiftlint` CLI isn't installed on this user's machine

Don't shell out to `swiftlint`. Do a manual read of `.swiftlint.yml` to get thresholds, then grep the code. The thresholds actually in use:

- `line_length: 150`
- `type_body_length: warning 300, error 400`
- `file_length: warning 500, error 1000`
- `function_parameter_count: warning 10, error 20`

Don't invent values like "file_length warning 400" and flag Audio.swift (currently ~450 lines) as over limit — the real warning threshold is 500.

### `xcodebuild` is broken on this machine

Unrelated `IDESimulatorFoundation` plugin load failure from Xcode. Don't try to run it. Use `swiftc -typecheck` as documented.

## When in doubt

If you spot something that looks like a bug and it's listed above: it isn't. If it's NOT listed and looks real: cross-check against the relevant subsystem section of `docs/ARCHITECTURE.md` before raising it. The architecture doc explains the load-bearing patterns in detail.

If your "finding" requires three exclusions to justify ("but only on drivers that do X, and ignoring the documented aggregate model, and assuming the debouncer is reentrant…"), it's almost certainly theoretical rather than actionable.
