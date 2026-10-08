# Contributing

Thanks for helping. This app moves real garage doors, so changes are reviewed for safety first and features second. Read [SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md) before you start.

## Setup

1. Install **Xcode 26** (iOS 26 SDK) and XcodeGen (`brew install xcodegen`). Python 3.11 or newer runs the gatectl tests.
2. Copy `ios/GarageTiles/Config/Signing.local.xcconfig.example` to `Signing.local.xcconfig`, and set your team ID and a bundle ID prefix unique to you.
3. **Sign-in needs a value this project doesn't provide.** A clean clone builds, runs and passes every test without it, but **Sign in with myQ** shows "not set up". Sign-in needs a Firebase App Check debug token in `config/MyQ.local.xcconfig` (see the `.example`), and this project does not distribute, explain how to obtain, or authorize the use of any such credential. Whisper Lift is an unsupported personal integration with an undocumented service, not a turnkey myQ client or SDK.
4. Run `xcodegen generate` in `ios/GarageTiles`. The Xcode project is generated, so edit `project.yml`, never the `.xcodeproj`.

[docs/phase-0-spike.md](docs/phase-0-spike.md) has the full device setup.

## Checks

Every check runs offline. None of them signs anything, contacts myQ, or moves a door.

| Command | What it does |
| --- | --- |
| `script/test` | Swift Testing suite, including seeded property tests, with warnings as errors |
| `script/typecheck` | Type-checks the app and widget sources |
| `script/sanitize` | Runs the package tests under Thread, Address and Undefined Behavior sanitizers |
| `script/ci-ios` | iOS build plus Simulator UI and accessibility tests (needs about 11 GB of free disk) |
| `script/gatectl-test` | gatectl tests with the network blocked |
| `python3 script/gatectl_mutants.py` | Mutation check of the gatectl safety guards |
| `script/check-gitleaks-rule <gitleaks>` | Proves the App Check debug-token scan rule still catches fake tokens; CI runs it before every secret scan |
| `python3 script/kit_mutants.py` | Mutation check of the app's status, card, sign-out, export and sign-in logic; every mutant must be killed |

CI runs all of these on every pull request.

## Pull requests

- Branch from up-to-date `main`. Keep each pull request to one concern.
- Write a failing test before the fix. Add a seeded property test (`PropertyTestSupport`) wherever an invariant can be stated.
- Use only fabricated data in tests, fixtures, logs and screenshots: no real tokens, serials, account IDs, door names or homes.
- Write every code comment on a single line. When you edit a multi-line comment, condense it to one line.
- Fill in the pull request template. Report the exact checks you ran, and keep physical-device testing separate from automated testing.
- Every change goes through a pull request with green checks; nothing is pushed straight to `main`. A second reviewer isn't required yet, so the maintainer reviews each change against the template. A green CI run, or an AI agent saying the change is ready, is not a review.

## Changes that need extra care

- **Door commands and safety checks** (`SafetyPolicy`, `DoorCommandService`, the intents): explain each behavior change and add regression tests. A command must never be retried after an unproven outcome.
- **Sign-in, tokens and network hosts:** do not add hosts, log secrets, or weaken validation of the callback URL or the token response.
- **`vendor/gatectl`:** any change produces a new tree hash and reopens the security gate in [docs/gatectl-security-review.md](docs/gatectl-security-review.md). Only the owner can approve the new tree.

## Testing on a real door

Only test door commands with a person watching the door and the wall control within reach. Start with the door closed and the doorway clear. Never test from a moving vehicle. Report device results separately from automated results, with the date, the iOS version and the opener model.
