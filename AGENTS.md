# Agent guidance for Whisper Lift

Read this file first. Then read [PLAN.md](PLAN.md) and [docs/gatectl-security-review.md](docs/gatectl-security-review.md) completely before changing anything.

## Where the project stands

| Phase | State |
| --- | --- |
| Phase 0: CarPlay and free-signing spike | **Partly verified on a device.** Automated tests pass (`script/test`), and CI builds for iOS 26 and runs Simulator UI tests. On 2026-10-07 the app was signed with the free Personal Team and installed on an iPhone (A1 to A3 pass, A4 partial). The widget, locked-phone and CarPlay checks are still to be observed by the owner. See [docs/phase-0-spike.md](docs/phase-0-spike.md). |
| Phase 1: gatectl security gate | **Passed 2026-10-07** for `vendor/gatectl` tree `c1e39969…`, which moves the App Check debug token out of the source (GQ-07). Earlier passes for `e200f354…` and `e0eba7c2…` are superseded. Any change under `vendor/gatectl`, or any re-review trigger, reopens the gate. |
| Phases 2–9 | The testable core for Phases 4–8 is in `GarageDoorKit` (see [docs/garage-door-kit.md](docs/garage-door-kit.md)). **The app uses it:** the Doors tab and the Siri intents send real myQ door commands. Every phase that uses myQ credentials or moves a door is still blocked until Phase 1 records an explicit pass. |

## What to do next

Work out which situation applies before doing anything.

1. **The owner has not reported Phase 0 device results yet.** Do not start the myQ client (Phases 3–9). You may still:
   - help the owner build in Xcode 26 and fix compile errors in `ios/GarageTiles`;
   - run `script/test` and `script/typecheck` after every change;
   - record the owner's observed results in the checklist in `docs/phase-0-spike.md` and in "Phase 0 status" in PLAN.md, with date, iOS version and vehicle model.
2. **The owner reports a Phase 0 failure:** the vehicle cannot interact with widgets, the two-widget layout is unusable, or free signing rejects App Groups. Stop and discuss alternatives with the owner. Do not continue to Phase 1 on your own.
3. **The owner says Phase 0 passed, or explicitly asks for Phase 1 now.** Do Phase 1 only, as the next section describes.
4. **Phase 1 passed** (owner decision, 2026-10-07, tree `c1e39969…`). Phase 2 runs only through `script/gatectl_session.py`, with the owner typing credentials in their own terminal. Keep `script/gatectl-test` and `script/gatectl_mutants.py` passing. Any change under `vendor/gatectl` changes its tree hash and reopens the gate. Never fill in or change the owner fields yourself.

## Phase 1 task (next once Phase 0 is cleared)

Follow "Phase 1: gatectl security gate" in PLAN.md and the "Required approval checklist" in the security review:

1. Import upstream `cnberry/gatectl` at exactly commit `47ef70d368f557d496331d51a3c65576bca05bda` into `vendor/gatectl`. Keep its MIT license and record provenance: the upstream URL, the commit SHA, and the import method.
2. Patch GQ-01 (OAuth origin allowlist and exact callback match), GQ-02 (never retry a physical PUT), and GQ-03 (re-fetch and re-check by account ID and serial after confirmation). Also add the GQ-04 bounded reads and the GQ-06 private-directory checks.
3. Add every negative and physical-command regression test that the review lists. Tests use fakes or loopback fixtures only.
4. Run the static checks, a secret scan, the full tests, a compile check and an offline smoke test from a clean checkout. Review the complete upstream-to-patched diff.
5. Write the approval record into the security review: the exact patched commit, the reviewer, the date, the checks run, the residual risks, the re-review triggers, and an explicit pass or fail. A human owner makes the final pass decision. An agent may recommend but must not self-approve.
6. Stop and hand off. Phase 2, the first real login, is done by the owner under supervision.

## Hard rules

- Never request, accept, store, or use myQ email addresses, passwords, MFA codes, access or refresh tokens, or real door access. If the owner pastes one, tell them to rotate it, and do not repeat it.
- Never run `vendor/gatectl` against the network, never run its `script/install`, and never use `--yes`. Auditing and running tests with fakes is allowed.
- Never claim a locked-phone, CarPlay, Siri or vehicle check passed unless the owner physically observed it. Update PLAN.md only for checks that were genuinely completed.
- Never commit secrets, signing identities, team IDs, provisioning profiles, `Signing.local.xcconfig`, the generated `GarageTiles.xcodeproj`, `DerivedData`, or `xcuserdata`. `.gitignore` covers these, so check `git status` before committing anyway.
- Decision, 2026-10-06: the owner chose Siri as the primary in-car control, so myQ code now lives in the app (the Doors tab, `OpenDoorIntent`, `CloseDoorIntent`). The counter spike stays on its own tab for the widget and App Group checks, and its counter is still its only side effect.

## Working in this repository

- Run the automated tests with `script/test` and the offline type-check with `script/typecheck`. Both need only the Swift toolchain.
- To build the iOS project, use Xcode 26 and XcodeGen: run `xcodegen generate` in `ios/GarageTiles`. The Xcode project is generated, so edit `project.yml`, not the `.xcodeproj`.
- Shared, testable logic goes in the `GarageTilesKit` Swift package with Swift Testing tests: spike code in the `GarageTilesKit` target, door and myQ code in `GarageDoorKit`. Write failing tests before fixes, and add a seeded property test (`PropertyTestSupport`) wherever an invariant can be stated.
- Write every code comment on a single line: one `//` line, a one-line `/** ... */`, or one `#` line. When an edit touches a multi-line comment, condense it to one line.
- The remote is `github.com/elearningplugins/whisper-lift`. Work on a branch off up-to-date `main`, and commit or push only when the owner asks.
