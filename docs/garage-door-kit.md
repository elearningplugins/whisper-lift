# GarageDoorKit: door, token and myQ client logic

`ios/GarageTiles/GarageTilesKit/Sources/GarageDoorKit` holds the testable core for PLAN.md Phases 4 to 8. **The app links it:** the Doors tab, `OpenDoorIntent` and `CloseDoorIntent` use it to send real myQ commands once the owner signs in. The counter widget does not use it yet.

Nothing here has contacted myQ. Every test uses fakes or an in-process `URLProtocol` stub.

## Modules

| File | PLAN.md | What it does | Tests |
| --- | --- | --- | --- |
| `DoorState.swift` | Phase 5 | Normalizes `door_state` to open, closed, opening, closing, stopped or unknown; anything unrecognized is unknown | `DoorStateTests`, including a property that normalization never invents a terminal state |
| `DoorIdentity.swift` | Phase 7 | Stable identity from account ID and serial; a length-prefixed entity identifier that cannot collide | `DoorIdentityTests`, round-trip property over arbitrary strings |
| `MyQModels.swift` | Phase 5 | Parses accounts and devices; wrong-typed safety flags become nil, never false | `DeviceParsingTests` |
| `SafetyPolicy.swift` | Phase 5 door safety policy, Phase 7 idempotent intents | Decides send, already satisfied, or refuse from live state, in-flight and cooldown | `SafetyPolicyExamples`; properties: every send passed every guard, explicit open or close is never inverted, toggle always moves away from the current state |
| `TokenRecord.swift`, `TokenCoordinator.swift` | Phase 4 | One token record with a generation; refresh under an App Group flock with re-read, keep-old-refresh-token, persist-before-use and the `invalid_grant` generation rule; refresh after a rejected token | `TokenCoordinatorTests` including app and widget refreshing together with one myQ call; `TokenRecordTests` redaction in every textual form |
| `MyQMetadata.swift` | Phase 5 | Client metadata pinned from gatectl 47ef70d, the four allowed myQ hosts plus the Firebase App Check host used at sign-in, ID escaping | `HostAllowlistTests` |
| `MyQClient.swift` | Phase 5 request policy | GET retries once after 401 or 403; PUT is sent once and any unproven outcome is `CommandError.outcomeUnknown`; 429 keeps `Retry-After`; refresh-token exchange recognizes `invalid_grant` | `MyQClientReadTests`, `MyQClientCommandTests`, `MyQTokenRefresherTests` |
| `URLSessionTransport.swift` | Phase 3 network limits | myQ hosts only, no redirects, no cookies or cache, 15 and 30 second timeouts, 1 MiB streamed body cap | `URLSessionTransportTests` with a `URLProtocol` stub |
| `DoorSnapshot.swift` | Phase 4 cached snapshot, Phase 8 widget | Non-secret snapshot file under an App Group flock; `TilePresentation` marks stale state and offers an action only for a confirmed online terminal state | `DoorSnapshotStoreTests`, `TilePresentationTests` with an action property |
| `KeychainTokenStore.swift` | Phase 4 token record | Data-protection Keychain item in the shared access group, never synchronized, accessible after first unlock on this device only; update-or-add; locked or misconfigured Keychain is `storeUnavailable` | `KeychainTokenStoreTests` with a fake backend |
| `TokenImport.swift` | Phase 6 token import | Trims and checks a pasted refresh token without echoing it, and builds a record that forces an immediate refresh | `TokenImportTests`, including a property over random pastes |
| `DoorCatalog.swift` | Phase 6 setup, Phase 7 door entity | Cached doors with aliases; spoken-name matching that ignores case, punctuation, a leading "the" and digits versus words, and drops aliases two doors share; discovery of every garage door; the App Group catalog file | `DoorCatalogTests`, including a property that every spoken name resolves to its door |
| `SessionImporter.swift` | Phase 6 token import | Validates, saves and proves a pasted token with one refresh; rolls back a rejected token | `SessionImporterTests` |
| `MyQConfiguration.swift` | Public-release configuration | Reads the App Check debug token from the Info.plist key filled by the ignored `config/MyQ.local.xcconfig`; missing, unexpanded or malformed values are refused without echoing them | `MyQConfigurationTests`, including a check that no source file contains a UUID-shaped value |
| `MyQSignIn.swift` | Phase 6 in-app sign-in | PKCE (RFC 7636 S256), the authorization URL, strict `com.myqops://android` callback parsing with a state check, App Check, the code exchange, and saving the session as the next token generation under the refresh lock; nothing is saved on cancel or any failure | `PKCETests`, `CallbackParsingTests`, `SignInFlowTests`, `GarageEnvironmentSignInTests` |
| `GarageEnvironment.swift` | Phases 6 to 8 | Builds every service from the bundle's App Group and Keychain group and runs a request against a catalog door | `GarageEnvironmentTests` with a fake keychain and fake myQ |
| `DoorCard.swift`, `CheckThrottle.swift` | App design | Maps saved state to the design's cards; state 10 or more minutes old, a failed check, or "moving" for 45 seconds shows as an outlined "Last known" card; a tapped card shows Opening or Closing at once. `GarageEnvironment.refreshStatus` and `followUp` read live state (never a command) on open and every 5 seconds after a command until the door stops; `CheckThrottle` keeps launch to one check | `DoorCardTests`, `StatusRefreshTests`, `FollowUpTests`, `CheckThrottleTests`; `script/kit_mutants.py` |
| `Traffic.swift` | Diagnostics | `MeteredTransport` logs each myQ request (time, method, host, endpoint template, status, estimated sizes) to the last 500 entries in the App Group; `TrafficExport` turns the log into the shareable JSON file behind **Export request log (JSON)** | `MeteredTransportTests`, `TrafficExportTests`, including a property test that no account ID or serial reaches the export |
| `DoorCommandService.swift` | Phase 8 tap sequence, Phase 7 dialogs | Live read, policy, at most one PUT, optimistic snapshot, bounded follow-up reads, one re-read after an unknown outcome; spoken dialog for every outcome | `DoorCommandServiceTests` including double tap and a property of at most one command per tap |

## Mutation testing

Muter run on 2026-10-06 over every `GarageDoorKit` source: 74 mutants, 59 reported killed. Each reported survivor was re-applied by hand with `swift test`:

| Result | Mutants |
| --- | --- |
| Killed when applied by hand (Muter misreported) | The follow-up confirmation check, the `invalid_grant` ternary, the second-401 check, the `invalid_grant` generation comparison, and two of the file lock's errno checks |
| Real gaps, now killed | The snapshot store's lock loop (no contention test existed) and the `EINTR` retry in both locks: `DoorSnapshotStoreTests` now holds the lock from another descriptor, runs 12 concurrent writers, and injects `EBADF` and `EINTR` through an internal `tryLock` hook, as does `FileLockTests` |
| Equivalent | `clock.now <= deadline` in both lock loops: the continuous clock effectively never equals the deadline |

One mutant, removing `completionHandler(nil)` from `NoRedirects`, made the redirect test wait forever. The test now has a one-minute time limit so that regression fails instead of hanging. Muter has no per-mutant timeout, so a hung run has to be stopped by hand.

Muter cannot instrument an implicit-return `switch` that contains a mutable operator; such functions use `return switch`.

Second run, 2026-10-07, over the newer `DoorCatalog.swift`, `SessionImporter.swift`, `GarageEnvironment.swift` and `Traffic.swift`: 26 mutants, 18 reported killed. All 8 reported survivors were mutations inside closures in `DoorCatalog.normalize` and `DoorAliases.defaults`; each was re-applied by hand with `swift test` and every one was killed, so Muter did not instrument them. Effective result: 26 of 26.

## Other local checks

- `script/sanitize` runs the package tests under Xcode's thread, address and undefined-behavior sanitizers. `swift test --sanitize` cannot be used: macOS refuses to load sanitizer runtimes into SwiftPM's signed test helper and the tests then run unsanitized without any error. A planted two-thread race was confirmed to fail the script.
- Apple's static analyzer (`xcodebuild analyze`) covers only C and Objective-C and analyzes no files here; instead `script/test` and CI's device build treat every Swift warning as an error.
- `AccessibilityUITests` run Apple's accessibility audit on both tabs and check the Doors controls at the largest accessibility text size.

## Not done yet, and why

- **Keychain on a device.** `KeychainTokenStore` and its query attributes are tested through a fake backend; the real `SecItem` calls need a signed app with the Keychain access group.
- **Door widget.** The intents and `DoorEntity` are in `Shared/`, ready for a door widget once the widget check on the iPhone passes; Siri is the primary control.
- **Live myQ behavior.** Response shapes follow gatectl and the community references; the first real responses come in Phase 2 under supervision.

## Running

```sh
script/test   # runs GarageTilesKit and GarageDoorKit tests
```
