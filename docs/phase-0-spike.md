# Phase 0: CarPlay and free-signing feasibility spike

This spike checks the path from the user to the app before any myQ work starts. It builds a free-signed iPhone app and a `systemSmall` widget. Tapping the widget increments a mock counter shared through an App Group.

**Scope:** the spike itself (its app tab and counter widget were removed from the app on 2026-10-07; this document keeps the record), contains no myQ client, credentials or door commands; its only side effect is a small JSON counter in the App Group. **The same app now also has a Doors tab and Siri intents that send real myQ door commands** (see [garage-door-kit.md](garage-door-kit.md)), so treat any installed build as able to move the doors.

## What is in the repository

| Path | Purpose |
| --- | --- |
| `ios/GarageTiles/project.yml` | XcodeGen spec for the app target, widget extension, App Group entitlements and iOS 26 deployment target |
| `ios/GarageTiles/Config/Signing.xcconfig` | Shared signing defaults with placeholder values; it includes an optional local file |
| `ios/GarageTiles/Config/Signing.local.xcconfig.example` | Template for your untracked team ID and bundle ID prefix |
| `ios/GarageTiles/GarageTilesKit` | Swift package holding the counter model, the cross-process file lock and App Group resolution, plus automated tests |
| `ios/GarageTiles/Shared` | `IncrementCounterIntent` and the tile `AppEnum`, compiled into both the app and the widget extension |
| `ios/GarageTiles/GarageTilesWidget` | `SpikeCounterWidget` (`AppIntentConfiguration`, `systemSmall` only) and its separate configuration intent |
| `ios/GarageTiles/GarageTiles` | Diagnostics app screen and the `AppShortcutsProvider` used for Siri (door phrases only) |
| `script/test` | Runs the automated tests with the Swift toolchain |
| `script/typecheck` | Type-checks the app and widget sources against the macOS SDK without Xcode |
| `script/ci-ios` and `.github/workflows/ci.yml` | GitHub Actions: iOS device build without signing, Simulator UI tests, App Group entitlement check and a screenshot |
| `ios/GarageTiles/GarageTilesUITests` | UI tests that bump each tile from the app screen and check the App Group is readable |

### Behavior

- Each widget instance is configured as **Tile A** (orange, `a.square.fill`) or **Tile B** (teal, `b.square.fill`).
- Tapping anywhere on a widget runs `IncrementCounterIntent(tile:)` without opening the app (`openAppWhenRun = false`). The policy is explicitly `authenticationPolicy = .alwaysAllowed`.
- The counter stores the total, a count per tile, the last tile tapped, the time, and `lastWriter`. `lastWriter` is the bundle identifier of the process that ran the increment. A widget tap should show the widget extension's identifier. The app screen labels it "Other process".
- Increments hold an advisory `flock` on a lock file in the App Group, with a 2-second bounded wait. The data file is replaced atomically with `completeUntilFirstUserAuthentication` protection, so it should stay usable on a locked phone after the first unlock.
- If the counter cannot be read, the widget shows a reason instead of a number, and the app screen and Siri report the same reason:

  | Widget shows | Cause |
  | --- | --- |
  | App Group missing | The App Group identifier or container is unavailable: a misconfigured build, or free signing refused App Groups (check A3) |
  | Unlock iPhone | Data protection blocked the read or the lock file: after a reboot, before the first unlock (check A8) |
  | Busy, tap again | Another process held the lock for more than 2 seconds |
  | Counter damaged | The counter file exists but is not valid JSON |
  | Counter unavailable | Anything else; the app screen shows the underlying error |
- Siri App Shortcuts for the counter were removed on 2026-10-07. `IncrementCounterIntent` is `isDiscoverable = false` and runs only from the widget button, so it no longer competes with the door phrases or clutters Shortcuts.

## Automated tests

```sh
script/test
```

These tests need only the Swift toolchain; Command Line Tools are enough. They cover:

- the empty state
- increments that record the tile, writer and time
- separate per-tile counts
- sharing between store instances
- 200 concurrent increments from independent file descriptors with no lost updates
- the lock timeout while another holder has the lock
- malformed data being reported and not overwritten
- the stable on-disk format
- App Group identifier validation, including unexpanded `$(…)` build settings
- the mapping from each storage error to the reason the widget, app and Siri show
- the "Last writer" label for this app, another process, or no writer yet
- seeded property tests: increments conserve every tap, never change another tile's count, and `increment` returns exactly what a later read sees; accepted App Group identifiers are always expanded, prefixed and untrimmed

Property tests use a fresh random seed on each run. A failure prints the seed. Replay it with `GTK_PROPERTY_SEED=<seed> script/test`, then pin the case as a deterministic test. The first property run found that `increment` returned sub-second timestamps that the ISO 8601 file format drops; it now returns the snapshot as stored.

The concurrency test was checked by removing the lock: it then failed with 31 of 200 increments recorded.

### Type-checking without Xcode

```sh
script/typecheck
```

This type-checks `Shared`, `GarageTiles` and `GarageTilesWidget` against the macOS SDK from Command Line Tools, in Swift 6 mode with complete concurrency checking and warnings as errors. `#Preview` blocks are removed first because their macro plugin ships only with Xcode. It catches type and concurrency errors in the App Intents, WidgetKit and SwiftUI code. It does not prove the iOS 26 build: iOS-only APIs, the App Intents metadata processor, signing and the asset pipeline still need Xcode (check A2).

### iOS build and Simulator UI tests in CI

`.github/workflows/ci.yml` runs `script/ci-ios` on a GitHub macOS runner with Xcode 26. On 2026-10-06 it:

- built both targets for a generic iOS device without signing;
- ran `SpikeAppUITests` on an iPhone 17 Pro Simulator with iOS 26.2: the App Group reads as Readable, bumping Tile A and Tile B from the app changes only that tile, and the counter survives a relaunch;
- confirmed the app and widget entitlements both contain `group.com.example.change-me.GarageTiles`;
- uploaded the logs, the `.xcresult` bundle and a screenshot as the `ios-results` artifact.

The Simulator does not enforce Personal Team signing or data protection, and widgets cannot be placed on a Home Screen from a test, so this does not cover A3 or A5–A12.

### Mutation testing

[Muter](https://github.com/muter-mutation-testing/muter) runs against the Kit with `muter.conf.yml`:

```sh
brew install muter-mutation-testing/formulae/muter
cd ios/GarageTiles/GarageTilesKit && rm -rf .build && muter run --skip-update-check
```

Remove `.build` first, because Muter copies it into its mutated workspace and the copied module cache fails to build. Muter 16 also mis-offsets mutants after non-ASCII characters, so Kit sources spell them as escapes, such as `"\u{2013}"`.

Result on 2026-10-06: 12 mutants, 8 killed. Each reported survivor was re-applied by hand:

| Mutant in `CounterStore.withExclusiveLock` | Hand-applied result |
| --- | --- |
| `code != EWOULDBLOCK \|\| code == EINTR` | Killed by the timeout and concurrency tests; Muter misreported it |
| `code == EWOULDBLOCK && code == EINTR` | Killed; Muter misreported it |
| `code == EWOULDBLOCK \|\| code != EINTR` | Survived; now killed by `CounterStoreLockFaultTests`, which inject `EBADF` and `EINTR` through the store's internal `tryLock` hook |
| `clock.now <= deadline` | Survives. Equivalent: the continuous clock effectively never equals the deadline |

Treat Muter's survivors as leads and confirm them by hand before writing tests.

## Building with a free Personal Team

Requirements: macOS 15.6 or later, Xcode 26 with the iOS 26 SDK, XcodeGen (`brew install xcodegen`), an Apple Account, and an iPhone on iOS 26.

1. In Xcode, open **Settings → Accounts**, add your Apple Account, and note the **Personal Team** ID (10 characters).
2. Create the local signing file. It is gitignored:

   ```sh
   cd ios/GarageTiles
   cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
   ```

   Set `DEVELOPMENT_TEAM` to your team ID. Set `BUNDLE_ID_PREFIX` to something unique to you, such as `com.<yourname>.whisper-lift`. Personal Team bundle IDs are globally unique, and the free tier limits how many new App IDs you can register per week. Choose the prefix once and keep it.
   For the app's **Sign in with myQ**, also create the shared sign-in file at the repository root. It is gitignored too:

   ```sh
   cp ../../config/MyQ.local.xcconfig.example ../../config/MyQ.local.xcconfig
   chmod 600 ../../config/MyQ.local.xcconfig
   ```

   Set `MYQ_APP_CHECK_DEBUG_TOKEN` in it. The project does not distribute this value. Without it the app builds and runs, and Siri and door commands work with an existing session, but **Sign in with myQ** explains that sign-in is not set up. `script/gatectl_session.py` reads the same file for `gatectl login`.
3. Generate and open the project:

   ```sh
   xcodegen generate
   open GarageTiles.xcodeproj
   ```

4. In each target's **Signing & Capabilities** tab, confirm that automatic signing selected the Personal Team. Both targets should list the App Group `group.<prefix>.GarageTiles`. If Xcode reports that App Groups are unavailable for the free team, record that as a Phase 0 failure. It is one of the facts this spike exists to verify.
5. On the iPhone, enable **Settings → Privacy & Security → Developer Mode**. Connect the phone, select it as the run destination, and run the **GarageTiles** scheme.
6. The first time, trust the developer certificate under **Settings → General → VPN & Device Management**.
7. Free provisioning expires after about seven days. To renew, connect the phone and run again from Xcode. The App Group data should survive the reinstall as long as the bundle ID prefix is unchanged.

Do not commit `Signing.local.xcconfig`, `config/MyQ.local.xcconfig`, the generated `GarageTiles.xcodeproj`, `DerivedData`, `xcuserdata`, or provisioning profiles. `.gitignore` already excludes them.

## Testing with the CarPlay Simulator

1. Download **Additional Tools for Xcode 26** from [developer.apple.com/download/all](https://developer.apple.com/download/all/) and open **CarPlay Simulator** from its Hardware folder.
2. Connect the iPhone to the Mac with a cable. CarPlay Simulator connects to the physical phone; the Xcode iOS Simulator does not work for this.
3. Add both widgets in CarPlay, either through **Settings → CarPlay → <car> → Widgets** on the iPhone or in the CarPlay widgets page itself. Configure one as Tile A and one as Tile B. Configure them on the iPhone first if CarPlay does not offer configuration.
4. Tap each widget and confirm that only that tile's count changes and that the total increases by one.
5. Lock the phone and repeat. Then open the app and check that **Last writer** shows the widget extension.

## Acceptance checklist and what each check needs

Mark a check done only after you have observed it yourself. Record the date, iOS version and vehicle model next to it in PLAN.md.

| # | Check (PLAN.md Phase 0 step) | Needs | Status |
| --- | --- | --- | --- |
| A1 | Counter logic, cross-process lock and App Group ID validation pass automated tests | Swift toolchain only | **Passed** 2026-10-06 (28 tests, including property tests) |
| A2 | Project generates and both targets compile against the iOS 26 SDK (steps 1, 4) | Mac with Xcode 26 and XcodeGen | **Passed** 2026-10-06 in GitHub Actions: Xcode 26.3 builds the app and widget for a generic iOS device without signing, with App Intents metadata extracted for both. Signing with the Personal Team is still A3 |
| A3 | Free Personal Team signs both targets with the App Group enabled (step 2) | Apple Account, Xcode | **Passed** 2026-10-07: the Personal Team signed the app and widget with the App Group and the Keychain sharing group; the free profile lasts seven days |
| A4 | App and extension install together; the app screen shows App Group "Readable" (step 6) | Physical iPhone, Apple Account | Partial 2026-10-07: installed together on an iPhone running iOS 26; the Readable status has not been reported yet |
| A5 | Two widget instances, configured as Tile A and Tile B, are visibly distinct and count independently (step 5) | Physical iPhone | Not run |
| A6 | A widget tap increments without opening the app; Last writer shows the extension (step 7) | Physical iPhone | Not run |
| A7 | Tap works while locked after first unlock (step 8) | Physical iPhone | Not run |
| A8 | After a reboot and before first unlock, the widget shows "Unlock iPhone" and does not crash | Physical iPhone | Not run |
| A9 | App Shortcut appears in Shortcuts/Spotlight and "Bump Tile A in Whisper Lift" works through Siri, including while locked (step 9) | Physical iPhone, Siri enabled | Superseded 2026-10-07: the counter's Siri shortcut was removed; Siri is now checked with the door intents |
| A10 | Both widgets appear and respond on the CarPlay Simulator widgets page (step 10) | Physical iPhone, CarPlay Simulator on a Mac | Not run |
| A11 | Actual vehicle: widgets available, touch interaction works, layout of two widgets recorded (step 11) | Physical iPhone, the vehicle | Not run |
| A12 | Reinstall after the 7-day free-provisioning expiry keeps working and preserves the counter | Physical iPhone, Apple Account, a week | Not run |

Phase 0 stop rule from PLAN.md: if A11 shows the vehicle cannot interact with widgets, or the layout fails the minimum usability requirement, stop before Phase 1.

## Known limitations of the spike

- The app and widget build against the iOS 26 SDK in CI and with Xcode 26.3 locally, and run on an iPhone with iOS 26; the widget, locked-phone and CarPlay checks are still to be observed.
- If CarPlay does not show the widget, check whether the vehicle supports widgets at all before changing code. No CarPlay-specific modifier is used; the plan relies on iOS 26 showing `systemSmall` widgets automatically.
- `IncrementCounterIntent` is compiled into both targets so the widget button can run it in the extension. Siri may run it in the app process instead. `lastWriter` shows which process ran it.
