# Build, signing, and distribution posture

Companion to `CLAUDE.md`.

## Workspace vs project

**Always open `MultiSoundChanger.xcworkspace`.** Not `MultiSoundChanger.xcodeproj`. The workspace is what CocoaPods integrates into; opening the raw project drops the Pods integration and the build fails to link `MediaKeyTap` + the SwiftLint phase's `PODS_ROOT` resolution breaks.

## Typecheck without Xcode

`xcodebuild` on this user's machine is broken (`IDESimulatorFoundation` plugin load failure — unrelated to this repo). For automated verification in a non-interactive shell, use `swiftc -typecheck` directly:

```bash
# Emit the MediaKeyTap swiftmodule once (or whenever the pod is regenerated):
xcrun swiftc -emit-module \
  -target arm64-apple-macos11.0 \
  -module-name MediaKeyTap \
  -o /tmp/MediaKeyTap.swiftmodule \
  Pods/MediaKeyTap/MediaKeyTap/*.swift

# Then typecheck the app:
xcrun swiftc -typecheck \
  -target arm64-apple-macos11.0 \
  -module-name MultiSoundChanger \
  -I /tmp \
  -import-objc-header MultiSoundChanger/Other/MultiSoundChanger-Bridging-Header.h \
  MultiSoundChanger/Sources/AppDelegate/AppDelegate.swift \
  MultiSoundChanger/Sources/Classes/*.swift \
  MultiSoundChanger/Sources/Extensions/*.swift \
  MultiSoundChanger/Sources/Frameworks/*.swift \
  MultiSoundChanger/Sources/Stories/Stories.swift \
  MultiSoundChanger/Sources/Stories/Volume/VolumeViewController.swift \
  MultiSoundChanger/Sources/Utils/*.swift \
  MultiSoundChanger/Other/Constants.swift \
  MultiSoundChanger/Other/Images.swift \
  MultiSoundChanger/Other/Localization/Strings.swift
```

Expected output: empty. The previous two `NSWorkspace.launchApplication` deprecation warnings have been resolved. Anything else means you've introduced a regression.

**Do NOT trust SourceKit single-file diagnostics** emitted by the editor while you're editing a file. In isolation (no `-I` module path, no cross-file context) SourceKit will report "Cannot find type X" / "Cannot find 'Logger' in scope" for every cross-file reference. Those are almost always false — always cross-check with the full `swiftc -typecheck` command above before chasing them.

## CocoaPods

Two pods: `SwiftLint` (build-phase linter) and `MediaKeyTap` (CGEventTap wrapper). Both are dynamic (`use_frameworks!`).

- **`MediaKeyTap` is pinned by commit hash**, NOT by branch. The Podfile uses `:commit => '22293b608bb9e7072960a2002d77ebbbdb3ba859'` against `the0neyouseek/MediaKeyTap`. Do not switch back to `:branch => 'master'` — a floating branch is a supply-chain attack vector.
- **`SwiftLint` is pinned to `'~> 0.51'`** — tilde-constraint semver. A breaking 1.x release won't walk in silently.

`Podfile`'s `post_install` hook applies Xcode-recommended build hygiene to every pod target on each `pod install`, because `Pods.xcodeproj` is regenerated every install and any manual edits would be wiped. The hook currently sets:

- `MACOSX_DEPLOYMENT_TARGET = '11.0'`
- Drops `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES` + `EMBEDDED_CONTENT_CONTAINS_SWIFT` (Swift runtime ships with macOS 10.14.4+)
- Drops any explicit `ARCHS` override (Xcode auto-picks)
- `DEAD_CODE_STRIPPING = YES`
- Clears `STRIP_INSTALLED_PRODUCT` / `STRIP_STYLE` / `STRIP_SWIFT_SYMBOLS` (reset to defaults)
- `ENABLE_PARALLELIZATION_IN_CLI_BUILDS = YES`

Module Verifier is deliberately NOT enabled for pods — it only matters for targets that define clang modules (our Swift-only pods don't), and turning it on blindly can trip on third-party header conformance we can't fix.

**If `pod install` ever surfaces new warnings about `inhibit_warnings` or a pod version change, commit both `Podfile` and `Podfile.lock`. `Pods/` itself is gitignored.**

## Hardened Runtime + entitlements

Both Debug and Release target configurations in `project.pbxproj` have:

```
ENABLE_HARDENED_RUNTIME = YES;
CODE_SIGN_ENTITLEMENTS = MultiSoundChanger/Other/MultiSoundChanger.entitlements;
```

`MultiSoundChanger.entitlements` declares exactly one Hardened Runtime exception:

```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

**Why**: CocoaPods' `use_frameworks!` embeds MediaKeyTap into the .app bundle as a dynamic framework. Hardened Runtime's default library-validation check refuses to load embedded dylibs unless they share a Team ID with the main binary. We sign ad-hoc (`CODE_SIGN_IDENTITY = "-"`) for open-source source-built distribution, which has no team, so without this exception the exported .app fails to launch with a library-load error.

**Symptom this was introduced to fix**: Xcode test-build runs work (Launch Services is permissive for direct-run-from-DerivedData), but `Product → Archive → Export → double-click the .app` fails silently or with a Console error like `code signature in <MediaKeyTap.framework> not valid for use in process: library load disallowed by system policy`.

**Narrow scope**: library validation only. This exception does NOT weaken sandbox (none in use), JIT, debugger attach, or Apple Events posture. A real attack requires write access to the .app bundle, which is a precondition strictly worse than dylib injection.

**What's still NOT declared** (and should only be added if a new feature concretely demands it):

- App Sandbox — CGEventTap (via MediaKeyTap) is incompatible with sandbox.
- `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` — no JIT.
- `com.apple.security.automation.apple-events` — `NSWorkspace.openApplication(at:configuration:)` and `NSWorkspace.open(URL)` use LaunchServices, NOT Apple Events.
- `com.apple.security.cs.allow-dyld-environment-variables` — we don't use DYLD vars.

**If shipping via Developer ID + notarization later**: the library-validation exception can be removed. CocoaPods' standard xcconfig re-signs embedded frameworks with the same team as the main binary during a Developer ID build, so library validation passes naturally.

## Code signing

`CODE_SIGN_IDENTITY = "-"` is ad-hoc signing — appropriate for local development but not distributable. For distribution:

1. Set `CODE_SIGN_IDENTITY` to `"Developer ID Application"` (for direct distribution outside the App Store) on the Release config.
2. Set `DEVELOPMENT_TEAM` to the team ID.
3. Build the Release scheme: `xcodebuild -workspace MultiSoundChanger.xcworkspace -scheme MultiSoundChanger -configuration Release archive -archivePath build/MultiSoundChanger.xcarchive`.
4. Export as a Developer ID app: `xcodebuild -exportArchive -archivePath build/MultiSoundChanger.xcarchive -exportPath build/MultiSoundChanger-release -exportOptionsPlist ExportOptions.plist`.
5. Notarize: `xcrun notarytool submit build/MultiSoundChanger.app.zip --apple-id <...> --team-id <...> --password <app-specific-pw> --wait`.
6. Staple: `xcrun stapler staple build/MultiSoundChanger.app`.

The app is ready for this pipeline — Hardened Runtime is on, entitlements are set, and no blocking issues. The user's side of the work: obtain a Developer ID certificate + app-specific password, and optionally wire this into CI.

## Info.plist

Keys that matter:

- `LSUIElement = true` — no dock icon, menu-bar only.
- `LSMinimumSystemVersion = $(MACOSX_DEPLOYMENT_TARGET)` — resolves to 11.0 via the Xcode build setting.
- `NSMainStoryboardFile = Main` — entry point. `Main.storyboard` contains the AppDelegate customObject; `customModule = "MultiSoundChanger"` (fixed in earlier commit — used to be `"DynamicsIllusion"` from whatever project this forked from).
- `NSPrincipalClass = NSApplication`.
- `NSAccessibilityUsageDescription` — required for the Accessibility prompt. Explains to the user (and to reviewers looking at a notarized binary) why the app asks for this permission.

## Xcode "Update to recommended settings" dialog

Xcode will periodically pop this dialog with "Perform Changes" recommendations. Rules of thumb:

- **For the main `MultiSoundChanger` project**: safe to click Perform Changes. Those edits land in the tracked `project.pbxproj` and can be reviewed as a git diff. Exception: `Enable User Script Sandboxing` may break the SwiftLint build phase — if SwiftLint stops running after applying, disable the phase's "Based on dependency analysis" toggle (which is also how we fixed the "run during every build" warning).
- **For the `Pods` project**: do NOT click Perform Changes. Those edits land in `Pods.xcodeproj` which CocoaPods regenerates on next `pod install`, wiping the changes. Add the equivalent build settings to `Podfile`'s `post_install` hook instead (see above).

## SwiftLint phase

In `project.pbxproj` the SwiftLint `PBXShellScriptBuildPhase` has `alwaysOutOfDate = 1;` set — equivalent to unticking "Based on dependency analysis" in the Build Phase inspector. SwiftLint produces diagnostics, not output files; Xcode's dependency analysis would otherwise warn "will be run during every build". The phase is deliberately unconditional on Debug and early-exits on Release.

## Git workflow

- Branch: `claude/rebuild-x86-app-011CV4gXVczxQsxNuHeA9X9o`.
- Upstream PR: #39 on `rlxone/MultiSoundChanger`.
- Push: `git push origin claude/rebuild-x86-app-011CV4gXVczxQsxNuHeA9X9o`. Credentials live in macOS Keychain via the `osxkeychain` git helper; no manual auth needed.
- `.gitignore` excludes `Pods/`, `*.xcworkspace`, `Podfile.lock`, `.DS_Store`. **`Podfile.lock` is in `.gitignore` — don't commit it.** (Some projects commit it; this one doesn't, which means every fresh clone may resolve to slightly different pod versions. The `:commit` pin on MediaKeyTap and `:version` constraint on SwiftLint keep this safe.)
