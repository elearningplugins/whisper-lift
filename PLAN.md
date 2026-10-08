---
name: myQ on CarPlay
overview: Two configurable, tappable garage-door widgets on the iOS 26 CarPlay widgets page, plus explicit Siri open and close actions, delivered as a small personal iPhone app. A one-time Mac login supplies an isolated myQ refresh-token session. No HomeKit hardware or required subscription; free signing requires weekly reinstall.
todos:
  - id: feasibility-spike
    content: Build a free-signed app and systemSmall widget that share a counter through an App Group; verify two widget instances, locked-phone interaction, App Intents, Siri App Shortcuts, and the actual vehicle's CarPlay layout before writing the myQ client
    status: pending
  - id: gatectl-security-gate
    content: Review and pin gatectl without using real credentials, document provenance and findings, patch origin validation and physical-command safety issues in a vendored fork, add regression tests, and approve the exact resulting commit before any login or door command
    status: completed
  - id: gatectl-pin-login
    content: After the security gate passes, configure isolated Mac token and target files, run the patched gatectl source directly with a hidden password prompt, then run doctor/login/inspect/status and one supervised open and close per door without --yes
    status: pending
  - id: phone-session
    content: Create a second myQ login in a separate token file, prove the Mac and phone sessions remain independent, import only the phone refresh token, and stop using that Mac token file after import
    status: pending
  - id: xcode-project
    content: Create ios/GarageTiles with an app target, widget extension, shared App Group and Keychain access group, Personal Team signing, and an iOS 26 deployment target
    status: pending
  - id: shared-storage
    content: Implement a shared after-first-unlock Keychain token record, an interprocess refresh lock with generation checks, and an atomically written cached door snapshot in the App Group
    status: pending
  - id: myq-client
    content: Implement refresh, accounts, devices, guarded open/close, bounded retries, error classification, and state confirmation using pinned myQ client metadata
    status: pending
  - id: app-ui
    content: Add token import, discovered-door setup, state and freshness display, explicit open/close test controls, diagnostics, and sign-in recovery without logging secrets
    status: pending
  - id: intents
    content: Implement cached DoorEntity lookup, idempotent OpenDoorIntent and CloseDoorIntent for Siri, ToggleDoorIntent for widgets, App Shortcuts with app-name phrases, and explicit locked-device authentication policy
    status: pending
  - id: widget
    content: Implement a systemSmall AppIntentConfiguration widget with a separate door-selection intent, a single toggle button, cached state and freshness, optimistic moving state, and best-effort reload after commands
    status: pending
  - id: test
    content: Run mocked client and concurrency tests, test on a physical iPhone with CarPlay Simulator, then validate both widgets and Siri in the actual vehicle while locked, offline, rate-limited, and after token rotation
    status: pending
isProject: false
---

# Garage tiles on CarPlay

## Goal

Build a small personal iPhone app that exposes two configurable `systemSmall` widgets in iOS 26 CarPlay, one for each garage door. Each widget shows the last known door state and lets the driver request the opposite action with one tap. The action fetches live state before deciding whether to open or close.

Provide Siri as a backup through explicit, idempotent open and close actions. No HomeKit bridge or additional garage hardware is required. A free Apple Developer account is sufficient for the first version, with the tradeoff that the app must be rebuilt and reinstalled about every seven days.

Success means:

- Two separately configured widget instances are available on the vehicle's CarPlay widgets page.
- A tap works while the iPhone is locked after its first unlock following a reboot.
- The app never turns an explicit Siri request to open into a close, or vice versa.
- Every command checks live myQ state and device eligibility first.
- A stale or uncertain state is displayed as stale or uncertain, never as a confirmed terminal state.
- Token rotation remains correct when the app and widget extension run concurrently.

CarPlay controls the final widget layout. The plan does not promise that both widgets will always appear side by side or directly on the map-and-media Dashboard.

## Platform facts and constraints

- iOS 26 CarPlay can display `systemSmall` widgets from an iPhone app even when the app has no CarPlay-app entitlement.
- Widget interaction is available only on touchscreen vehicles.
- CarPlay widgets normally run while the iPhone is locked, so storage needed by the widget cannot use protection that becomes unavailable on lock.
- App Groups and Keychain Sharing are supported by free Apple Developer accounts, but Personal Team App IDs and provisioning profiles expire after seven days.
- App Shortcut trigger phrases must include the app name or an app-name synonym. An exact phrase such as "Open the big garage" requires a personal Shortcut with that name or acceptance of Siri's flexible matching; the app-provided phrase will be "Open the big garage with Garage Tiles" or similar.
- WidgetKit does not provide a continuous process or guaranteed second-by-second refresh. Timeline dates are advisory, and normal timeline entries should not be scheduled seconds apart.

Primary Apple references:

- [Turbocharge your app for CarPlay](https://developer.apple.com/videos/play/wwdc2025/216/)
- [Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
- [Supported capabilities for iOS](https://developer.apple.com/help/account/reference/supported-capabilities-ios)
- [Apple Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Spotlight your app with App Shortcuts](https://developer.apple.com/videos/play/wwdc2023/10102/)
- [App Intent authentication policy](https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy)
- [Keychain accessibility after first unlock](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)

## Architecture

```text
Reviewed gatectl fork ---> Mac gatectl login A ---> Mac diagnostic token session

Reviewed gatectl fork ---> Mac gatectl login B ---> one-time refresh-token handoff ---> shared Keychain token record
                                                               |
                                          +--------------------+--------------------+
                                          |                                         |
                                  GarageTiles app                           widget extension
                                          |                                         |
                                  explicit test UI                     cached state and button
                                          |                                         |
                                          +----------> shared MyQ client <-----------+
                                                               |
                                                     interprocess refresh lock
                                                               |
                                                          myQ cloud

App Group container <--- cached door catalog, state, freshness, errors, and lock file
```

The refresh token is stored as a single shared Keychain record using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and a non-synchronizing, this-device-only access group. It is not stored in `UserDefaults`, source code, logs, widget configuration, or the cached state file.

The App Group contains non-secret cached data and the interprocess lock file. Cached files use complete-until-first-user-authentication protection so they remain accessible after the phone has been unlocked once and subsequently locks.

## Phase 0: prove CarPlay and free signing first

Before implementing myQ, create the smallest possible app and widget:

1. Create an iOS 26 app target and widget extension.
2. Enable one App Group on both targets using the free Personal Team.
3. Store an integer counter in the App Group.
4. Expose a `systemSmall` widget containing one App Intent button that increments the counter.
5. Add the widget twice with distinguishable configurations.
6. Confirm the app and extension install together and the App Group is readable from both.
7. Confirm the intent runs without opening the app UI.
8. Confirm interaction with the phone locked after first unlock.
9. Confirm an App Shortcut is discoverable and callable through Siri under free signing.
10. Connect the physical iPhone to Apple's CarPlay Simulator for macOS and verify the widgets page.
11. Test the actual vehicle and record whether it supports touch interaction and how it lays out two widgets.

Stop if the actual vehicle cannot interact with the widgets or if the observed layout does not meet the minimum usability requirement. This avoids building the unsupported myQ integration before validating the user-facing path.

### Phase 0 status

The spike source is in `ios/GarageTiles`. Build, signing, and device-test instructions, plus the full acceptance checklist, are in [`docs/phase-0-spike.md`](docs/phase-0-spike.md).

Completed:

- 2026-10-06: Automated tests for the shared counter, cross-process lock, and App Group identifier validation passed (`script/test`, 14 tests, Swift 6.1.2 on macOS 15.7). A mutation check confirmed that the concurrency test fails when the lock is removed.
- 2026-10-06: Added property tests, failure-reason and writer-label tests (`script/test`, 28 tests). A property test found that `increment` returned a timestamp more precise than the stored one; fixed. `xcodegen generate` succeeds, and `script/typecheck` type-checks the app and widget sources against the macOS 15 SDK in Swift 6 strict-concurrency mode. Muter mutation results are in `docs/phase-0-spike.md`.
- 2026-10-06: GitHub Actions (Xcode 26.3) builds both targets for a generic iOS device without signing and passes Simulator UI tests on iOS 26.2: App Group readable, per-tile counts, counter survives relaunch, App Group entitlement on both targets (step 1 and acceptance check A2).

Not yet verified (steps 1–11 above): building with Xcode 26, Personal Team signing with an App Group, installation, two widget instances, running without opening the app, locked-phone taps, Siri, CarPlay Simulator, and the vehicle. The app and widget build against the iOS 26 SDK in CI and run in the iOS Simulator, but nothing has been signed with a Personal Team or run on a physical iPhone. The `feasibility-spike` todo remains pending until those checks are physically observed.

## Phase 1: gatectl security gate

No real email address, password, MFA code, refresh token, or garage-door command may be supplied to gatectl until this phase is complete. A temporary read-only audit clone may be used to inspect source and run tests with mocked data, but it is not an approved operational binary.

The initial review is recorded in [`docs/gatectl-security-review.md`](docs/gatectl-security-review.md).

Phase 1 status, 2026-10-06: upstream was imported verbatim into `vendor/gatectl` (provenance in [`docs/gatectl-provenance.md`](docs/gatectl-provenance.md)), GQ-01 to GQ-04 and GQ-06 were patched test-first, and 58 offline tests, a CLI smoke test, 23 targeted mutants, ruff, detect-secrets and gitleaks all pass. The owner recorded **pass** on 2026-10-06. On 2026-10-07 a review found GQ-03 lacked the fault and vacation re-checks; they were added, and the owner recorded **pass** for the corrected tree the same day. It covers upstream commit `47ef70d368f557d496331d51a3c65576bca05bda`. The review found no evidence of a backdoor, credential logger, hidden executable, unexpected runtime dependency, or unrelated network destination. It did find security and physical-safety weaknesses that must be patched before use:

1. Allowlist the exact HTTPS origins permitted during OAuth and reject cross-origin redirects or form actions before sending an email address, password, MFA code, or consent response. Parse the custom-scheme callback and compare its exact scheme, host, and path rather than using a string prefix.
2. Never automatically retry an `open` or `close` PUT after any response, timeout, connection failure, or authentication failure. Refresh credentials before a command when necessary; if a command outcome is uncertain, fetch state and require a new user decision.
3. After interactive confirmation, fetch the exact account ID and door serial again, then re-run every state and eligibility check immediately before sending the command. Select operational targets by stable IDs rather than mutable display names.
4. Add bounded response reads and tests for hostile redirect locations, cross-origin form actions, callback-prefix confusion, ambiguous PUT outcomes, changed state after confirmation, duplicate display names, and secret redaction.
5. Keep the operational fork in `vendor/gatectl`, preserve its MIT license, record the upstream and patched commit SHAs, and review the complete diff. Do not silently merge future upstream changes; each update starts a new review.
6. Run the supported Python test matrix, static checks, secret scan, syntax compilation, and an offline smoke test. Tests must use fakes or loopback fixtures and must never contact myQ or move a door.

The approval record must identify the exact commit, reviewer, date, checks run, known residual risks, and a clear pass or fail decision. A fail decision blocks every later phase that uses myQ credentials or controls a door.

Operational restrictions after approval:

- Run the audited checkout directly with a supported Python version and `PYTHONPATH=src python3 -m gatectl`; do not run `script/install` or install an unpinned package from the network.
- Use a user-owned directory with mode `0700` and token files with mode `0600`.
- Enter the myQ password only through the hidden interactive prompt. Do not use `MYQ_PASSWORD`, shell history, command-line arguments, source files, logs, or chat.
- Set explicit `GATECTL_CONFIG`, `GATECTL_TOKEN_FILE`, and `GATECTL_STATE_FILE` paths for every invocation.
- Never use `--yes` for the initial supervised commands.
- Stop if the checkout is dirty, the recorded commit does not match, a check fails, an unexpected host is contacted, or the observed behavior differs from the approved review.

## Phase 2: validate and isolate myQ access

Use only the patched and approved gatectl commit under `~/Documents/GitHub/myq-carplay/vendor/gatectl`. Start every session through `script/gatectl_session.py mac|phone-seed <gatectl arguments>`: it refuses to run until the approval record shows an owner pass, the `vendor/gatectl` tree matches the approved hash with no local changes, and `--yes` and `MYQ_PASSWORD` are absent, then runs gatectl with private `~/.config/myq-carplay` paths and a minimal environment. Verify the commit and clean working tree before each credential-bearing or door-control session. Run its source directly with `PYTHONPATH=src python3 -m gatectl`; do not use its system-wide installer.

Configure explicit private paths such as:

```text
~/.config/myq-carplay/mac-targets.json
~/.config/myq-carplay/mac-tokens.json
~/.config/myq-carplay/phone-seed-tokens.json
```

Pass those paths through `GATECTL_CONFIG` and `GATECTL_TOKEN_FILE` so no command accidentally operates on a different session.

### Diagnostic session

Status, 2026-10-06, run by the owner through `script/gatectl_session.py mac` on the approved tree:

- [x] `doctor`: the sign-in page was reachable with the expected form, every hop on the allowed identity origin.
- [x] `login --mfa email`: password typed at the hidden prompt; the session is in the private `mac-tokens.json`.
- [x] `inspect`: one account with two garage doors and a hub, all online.
- [x] Targets recorded in the private `mac-targets.json`, each door pinned to its full serial.
- [x] `status`: both doors matched by serial, closed and online.
- [x] Supervised open and close of the first door on 2026-10-06: each command confirmed interactively and the door moved as reported.
- [ ] Supervised open and close of the second door, deferred by the owner.
- [x] The separate phone-seed login, 2026-10-07; its refresh token was imported into the iPhone app through an on-screen QR code and the Mac copy was deleted.

1. Run `doctor` once.
2. Run `login --email <account> --mfa email` using a hidden password prompt.
3. Run `inspect` and record the exact account, door names, families, and serials in the private target file.
4. Run `status` for each door.
5. While physically supervising the opening, run one open and one close per door.
6. Verify the observed transitions and any unattended-operation flags, online state, faults, or vacation-mode behavior.

### Phone seed session

1. Set `GATECTL_TOKEN_FILE` to the separate phone seed path.
2. Perform a second login rather than copying the diagnostic session.
3. Verify each token file can independently read status.
4. Import only the phone session's refresh token into the app.
5. Exchange it immediately in the app, save the returned token record, and verify door discovery.
6. Stop using and remove the Mac phone-seed token file after successful import so a later Mac refresh cannot rotate the phone's token chain.
7. Treat clipboard transfer as a temporary exposure. Clear the token field and offer to clear the local pasteboard after the import succeeds.

### In-app sign-in

Status, 2026-10-07: built and unit-tested; not yet tried on the iPhone. The app's "Sign in with myQ" button opens myQ's own sign-in page in an ephemeral `ASWebAuthenticationSession`, so the password and any MFA code stay on myQ's page and the app never sees them. The app sends a PKCE challenge and a random state, accepts only the exact `com.myqops://android` callback with that state, gets a Firebase App Check token, exchanges the code, and saves the session to the shared Keychain as the next token generation. That replaces the phone-seed login and token paste. Token paste stays under "Advanced: import a token" as a fallback. The App Check debug token is not in the source: the app reads `MYQ_APP_CHECK_DEBUG_TOKEN` from the ignored `config/MyQ.local.xcconfig` (see `config/MyQ.local.xcconfig.example`), and without it sign-in stops with a setup message while Siri and door commands keep working. Signing in again replaces the current phone session; the Mac diagnostic session is separate and unaffected.

The Mac diagnostic session can show whether myQ is generally reachable, but it cannot prove that the phone's separate session is still valid.

## Phase 3: create the Xcode project

Status, 2026-10-07: the testable core for Phases 4 to 8 is in the `GarageDoorKit` target; see [`docs/garage-door-kit.md`](docs/garage-door-kit.md). The app's Doors tab and the Siri intents use it to send real door commands; the counter widget does not.

Create `ios/GarageTiles` in this repository with:

- `GarageTiles`, the SwiftUI iPhone app target.
- `GarageTilesWidget`, the WidgetKit extension.
- Shared model, storage, client, and intent code with explicit target membership or an `AppIntentsPackage` shared framework.
- An iOS 26 deployment target.
- Automatic signing with the Personal Team for the initial build.
- Distinct bundle identifiers for the app and extension.
- One App Group enabled on both targets.
- One shared Keychain access group enabled on both targets.
- Network access limited to the documented myQ HTTPS hosts.

Do not add a CarPlay-app entitlement. The product is an iPhone app with CarPlay widgets, not a template-based CarPlay app.

## Phase 4: shared storage and refresh coordination

### Token record

Store the access token, refresh token, access-token expiry, generation number, and last successful refresh date as one encoded Keychain value. Use a this-device-only accessibility class that remains available after first unlock. Never include token values in `Error`, `CustomStringConvertible`, analytics, or diagnostics output.

### Interprocess refresh transaction

An actor serializes refreshes inside each process, but that is insufficient because the app and widget extension are separate processes. Add a tested interprocess advisory lock, such as a lock file in the App Group container.

The refresh algorithm is:

1. Check whether the access token remains valid beyond a short expiry margin.
2. If refresh is needed, acquire the interprocess lock with a bounded wait.
3. Re-read the Keychain token record after acquiring the lock.
4. If another process already advanced the generation and the access token is now usable, release the lock and use it.
5. Otherwise send one refresh request.
6. If myQ returns a new refresh token, retain it; if it omits one, retain the existing refresh token.
7. Persist the complete replacement record immediately and atomically before any account, device, or command request.
8. Release the lock.
9. If refresh returns `invalid_grant`, re-read the stored generation. Retry only if another process advanced it; otherwise require a new phone login.

No local design can eliminate the small failure window in which myQ rotates a token and iOS terminates the process before the response is persisted. The app must expose a clear "Sign in again" recovery path.

### Cached snapshot

Store a non-secret snapshot containing:

- Account ID and display name.
- Door serial and display name.
- Normalized state.
- Online, unattended-action, vacation, and relevant fault flags.
- Last server update if supplied.
- Last successful fetch time.
- Last accepted command and time.
- A sanitized error category, never a response body that might contain credentials.

Write snapshots atomically and coordinate file replacement between processes. The widget may display a cached snapshot when a live fetch fails, but it must show its age and stale status.

## Phase 5: implement the myQ client

Use the current pinned implementations as interoperability references:

- [`cnberry/gatectl`](https://github.com/cnberry/gatectl)
- [`bvdcode/myq-home-assistant`](https://github.com/bvdcode/myq-home-assistant)
- [`jasongelman/home-control`](https://github.com/jasongelman/home-control)

Record the source commit for every copied constant or behavior and retain the required MIT license and notice material. Treat all endpoints and client metadata as unsupported and replaceable, not as a stable public API.

The initial endpoint set is:

```text
POST https://partner-identity.myq-cloud.com/connect/token
GET  https://accounts.myq-cloud.com/api/v6.0/accounts
GET  https://devices.myq-cloud.com/api/v6.2/Accounts/{accountId}/Devices
PUT  https://account-devices-gdo.myq-cloud.com/api/v6.0/accounts/{accountId}/door_openers/{serial}/open
PUT  https://account-devices-gdo.myq-cloud.com/api/v6.0/accounts/{accountId}/door_openers/{serial}/close
```

Send the current pinned `App-Version`, `BrandId`, `User-Agent`, OAuth client ID, and other required metadata from one constants file. Never scatter those values across request code.

### Request policy

- Set explicit connection and overall request timeouts.
- Refresh proactively before access-token expiry.
- On a GET returning `401` or `403`, refresh once and retry once.
- Respect `429` and server backoff information; do not loop.
- Validate status codes and response shapes before using data.
- Accept successful command responses with an empty body.
- Do not automatically repeat a PUT after a timeout, connection loss, or ambiguous response. Fetch state and report uncertainty instead.
- Minimize requests and never continuously poll from the widget extension.

### Door safety policy

Before any command, fetch live devices and locate exactly one door using the stored account ID and serial. Reject the action when:

- The device is missing or duplicated.
- Its device family is not `garagedoor`.
- It is offline.
- The requested unattended operation is not allowed.
- It reports a relevant active fault or blocked vacation state.
- Its state is moving, stopped, unknown, malformed, or stale because the live request failed.
- A command for that door is already in flight or inside the local cooldown window.

Normalize at least these states:

- `open`
- `closed`
- `opening`
- `closing`
- `stopped`
- `unknown`

Send each accepted command once. After acceptance, save an optimistic `opening` or `closing` state and perform at most a small number of bounded follow-up reads. If the final state is not observed in that window, retain a clearly provisional or stale display rather than claiming success.

## Phase 6: app setup and diagnostics UI

The app screen contains:

- A secure paste field for the phone refresh token.
- Import, validate, replace, and remove-token actions.
- A list of discovered accounts and garage doors.
- A setup step that assigns the friendly names "1-car garage" and "2-car garage" without changing the stable serial-based identity.
- Current state, online status, last updated time, and sanitized failure category.
- Separate Open and Close test buttons rather than a setup-screen toggle.
- One-tap Open and Close on the app screen. Decision, 2026-10-07: the owner removed the confirmation prompt, so the app acts like Siri; the live read, safety policy, per-door lock and cooldown still apply to every tap.
- A visible warning that CarPlay and Siri actions are deliberately allowed while the phone is locked.
- A "Sign in again" state when refresh is irrecoverable.

On successful discovery or rename, update the cached door catalog and call `AppShortcutsProvider.updateAppShortcutParameters()` so Siri can resolve the current entity names.

## Phase 7: App Intents and Siri

Status, 2026-10-06: the owner chose Siri as the primary in-car control; a CarPlay app screen would need Apple to grant the driving-task entitlement. Built and tested so far: `DoorCatalog` with spoken-name matching and aliases (big garage, small garage), `DoorDiscovery`, `SessionImporter`, `GarageEnvironment`, the `DoorEntity` query, `OpenDoorIntent` and `CloseDoorIntent` with `.alwaysAllowed`, App Shortcut phrases, and a Doors tab to sign in (or import a token), find doors, and test Open and Close with confirmation. Remaining: the phone-seed login, installing on the iPhone, and supervised Siri tests unlocked, locked and in the car.

### Door entity

`DoorEntity` uses a stable identifier derived from account ID and serial number. Its query resolves from the cached catalog, not from a network request, so widget configuration and Siri parameter resolution still work when myQ is temporarily unavailable.

Return the two configured doors from `suggestedEntities()`. Add useful display representations and aliases such as "small garage," "one-car garage," "big garage," and "two-car garage" where the App Intents APIs permit them.

### Explicit Siri actions

Implement separate intents:

- `OpenDoorIntent(door:)` fetches live state, returns success without a command if already open, opens only from confirmed closed, and rejects every other state.
- `CloseDoorIntent(door:)` fetches live state, returns success without a command if already closed, closes only from confirmed open, and rejects every other state.
- `ToggleDoorIntent(door:)` is reserved for direct widget interaction and is not advertised as an open or close Siri phrase.

Each result returns a short spoken dialog describing accepted, already satisfied, moving, offline, stale, blocked, or sign-in-required status.

Register App Shortcuts such as:

```text
Open <door> with Garage Tiles
Close <door> with Garage Tiles
```

Include a phrase without the door parameter so Siri can prompt for one. If the shorter exact phrases are required, create four personal Shortcuts named for the explicit action and door, then test those names in CarPlay.

### Locked-device policy

Set the authentication policy explicitly rather than inheriting a framework default. The selected behavior is `alwaysAllowed` because the primary use case occurs in CarPlay while the phone is locked. Document during setup that anyone able to invoke Siri on the locked phone or use the connected CarPlay display may operate the doors. A future security-hardening option can require authentication, but it will change the one-tap and hands-free experience.

Where supported, restrict action intent execution to the intended bundle using `allowedExecutionTargets`. This reduces execution variability but does not replace the interprocess token coordinator because the widget timeline provider still runs in the extension.

## Phase 8: widget

Create a dedicated `DoorWidgetConfigurationIntent` with one required `DoorEntity` parameter. Do not use the action intent as the configuration intent.

The widget supports only `systemSmall` and contains:

- Door friendly name.
- `door.garage.open`, `door.garage.closed`, or an appropriate moving/unknown SF Symbol.
- Open, Closed, Opening, Closing, Stopped, Offline, Unknown, or Sign In Again label.
- A compact stale or last-updated indicator.
- One button covering the intended action area and invoking `ToggleDoorIntent` for that configured door.

The timeline provider may make one guarded live-state request when WidgetKit asks for a timeline. On failure it returns the cached snapshot with a stale indicator. Use a conservative reload policy appropriate for status data; do not schedule second-by-second entries.

After a tap:

1. Fetch live state.
2. Apply the safety policy.
3. Send at most one command.
4. Save an optimistic moving snapshot after a confirmed accepted response.
5. Perform a short, bounded best-effort poll.
6. Save the newest observed snapshot.
7. Call `WidgetCenter.shared.reloadTimelines(ofKind:)`.

The reload request is a prompt to WidgetKit, not a guarantee that the tile will immediately render the terminal state.

## Phase 9: testing

### Automated tests

Use URL loading mocks or a protocol-backed transport; automated tests never contact myQ or move a door.

Cover:

- Refresh response with and without a replacement refresh token.
- Concurrent refresh attempts from simulated app and widget processes.
- Generation advancement after `invalid_grant`.
- Process failure before and after atomic token persistence where it can be simulated.
- Access-token expiry margins.
- GET retry after one `401` or `403`.
- No PUT retry after an ambiguous outcome.
- `429`, timeout, malformed JSON, empty successful command response, and unexpected status codes.
- Multiple accounts and duplicate door names.
- Every normalized door state.
- Offline, unattended-operation-disabled, vacation, and active-fault guards.
- Idempotent Siri open and close behavior.
- Toggle behavior only from confirmed terminal state.
- Double-tap and per-door cooldown behavior.
- Snapshot freshness and secret-redaction rules.

### Physical iPhone and CarPlay Simulator

Apple's CarPlay Simulator for macOS is distributed in Additional Tools for Xcode and connects to a physical iPhone. Test:

- Free Personal Team install and reinstall.
- Two widget instances with different door configurations.
- Locked-phone tap after first unlock.
- Behavior immediately after reboot before first unlock.
- Siri phrases with the app name.
- Optional personal Shortcut names.
- Cellular-only networking and Wi-Fi transitions.
- Airplane mode, DNS failure, timeout, and stale cached state.
- Token expiry and rotation while both app and widget are active.
- Rapid repeated taps.
- A door changed through the wall control or official myQ app between widget refresh and tap.

### Supervised vehicle acceptance

With a person watching the door area and an official control available:

1. Confirm both widgets are available in the vehicle's CarPlay widget settings.
2. Record their actual layout and whether the vehicle permits touch interaction.
3. Start with both doors closed and test one open and close cycle per tile.
4. Start with one door open and confirm the correct close action.
5. Tap while a door is moving and confirm no second command is sent.
6. Double tap and confirm only one command is sent.
7. Change a door through another control, then confirm the next tile tap uses live state rather than the stale display.
8. Test explicit Siri open and close for each door.
9. Confirm errors never display or log tokens, authorization headers, raw serials outside diagnostics, or response bodies containing sensitive data.

## Failure and recovery behavior

| Condition | User-visible behavior | Automatic behavior |
| --- | --- | --- |
| No token | Sign In Again | No network request or command |
| Token refresh rejected | Sign In Again | One generation re-read; no loop |
| Phone rebooted but not unlocked | Unlock iPhone once | Use placeholder or inaccessible-data state |
| Door offline or state unknown | Offline or Unknown | No command |
| Door moving or stopped | Opening, Closing, or Stopped | No command |
| Command response ambiguous | Check door | Fetch state once; never blindly repeat PUT |
| Rate limited | Temporarily unavailable | Respect backoff; no rapid retry |
| Widget state old | State plus stale age | Live check still occurs before any action |
| myQ metadata or endpoint changed | Service unavailable | Require an app update or new pinned constants |

## Risks and mitigations

### Unsupported myQ API

The residential API is undocumented. OAuth pages, Firebase App Check, client metadata, endpoints, Cloudflare behavior, and rate limits can change without notice. Pin reference commits, isolate constants, classify failures, and retain the official myQ app or wall control.

If command or refresh behavior changes, stop sending commands until the new behavior has been reviewed and tested through the Mac diagnostic client.

### Initial login blocked

Do not repeatedly run automated login through a Cloudflare challenge. Wait and retry `doctor` once later. As the preferred fallback, adapt the browser OAuth/PKCE flow documented by `bvdcode/myq-home-assistant`. Do not make mitmproxy interception part of the normal plan; treat it as a separate, explicitly approved security investigation only if browser authorization is unavailable.

### Token exposure

The refresh token can operate the doors. Protect it with a this-device-only Keychain record, exclude secrets from logs and crash diagnostics, and scan the repository before every commit. Universal Clipboard is temporary exposure and may involve nearby signed-in devices, so clear the local pasteboard after a successful import and never paste a real token into source control, an issue, a test fixture, or chat.

### Locked-device access

The convenience requirement deliberately permits actions while locked. Document the implication during setup, keep device and CarPlay access controlled, and allow the user to remove the token quickly from the app.

### Stale display

Widget state is advisory because WidgetKit schedules refreshes and myQ itself can lag command acceptance. Always display freshness and always fetch live state before acting.

### Free signing expiration

The initial Personal Team build expires after seven days. Record the reinstall steps in the project README. Enrollment in the paid Apple Developer Program can extend development signing validity, but it is optional and therefore not part of the no-required-subscription baseline.

## Deliverables

- Gatectl security review with an explicit pass or fail decision and recorded evidence.
- Patched `vendor/gatectl` fork with upstream and approved commit SHAs, preserved license, security regression tests, and a reviewed diff.
- Xcode app and widget project under `ios/GarageTiles`.
- Shared token coordinator, snapshot store, and myQ client.
- App setup and diagnostics screen.
- Three action intents and one widget configuration intent.
- Two configured CarPlay widget instances.
- Siri App Shortcuts and optional personal Shortcut instructions.
- Mocked automated tests and a recorded supervised acceptance checklist.
- README covering build, reinstall, token recovery, known limitations, and emergency fallback controls.

## Definition of done

The project is complete only when the actual vehicle passes the supervised acceptance test, both doors can be operated independently from their configured widgets, explicit Siri commands are idempotent, locked-device behavior is understood and documented, concurrent token rotation tests pass, stale state is never presented as authoritative, and a failed or ambiguous network operation cannot cause an automatic duplicate garage command.
