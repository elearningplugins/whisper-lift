# gatectl pre-use security review

## Decision

**Current decision: pass for tree `c1e3996937a493454dca51a7bd456d1490df2e05`, recorded by the owner on 2026-10-07.** It removes the Firebase App Check debug token from the source ([GQ-07](#gq-07-the-app-check-debug-token-is-in-the-source)); see [GQ-07 revision](#gq-07-revision). The previous pass, for tree `e0eba7c2c8e20046914579f6d1d79efff403ce12`, is superseded. The unpatched upstream revision still fails closed.

Earlier on 2026-10-07 the owner passed tree `e0eba7c2c8e20046914579f6d1d79efff403ce12` after a code review found that GQ-03 had been marked complete without the required fault and vacation re-checks; the guard was added and tested before that pass.

**Update 2026-10-06:** a patched revision is in `vendor/gatectl` (tree `e200f354192ef179ad706809ed4f773e633623d9`). The agent recommended **pass** for supervised Phase 2 use, and the owner recorded **pass** in the [approval record](#approval-record) below.

No evidence of malicious behavior, a backdoor, credential logging, hidden executable code, or an unexpected runtime dependency was found in the reviewed revision. However, the client accepts OAuth navigation and form destinations without a strict origin allowlist, automatically repeats physical write requests after some authentication failures, and can act on door state captured before a user confirmation delay. Those issues must be patched and regression-tested in this repository before login or device control.

This decision applies only to the exact source reviewed. It is not an endorsement of the repository owner, future commits, package releases, or the unsupported myQ API.

## Scope and identity

| Item | Reviewed value |
| --- | --- |
| Upstream | [`cnberry/gatectl`](https://github.com/cnberry/gatectl) |
| Commit | [`47ef70d368f557d496331d51a3c65576bca05bda`](https://github.com/cnberry/gatectl/commit/47ef70d368f557d496331d51a3c65576bca05bda) |
| Review date | 2026-10-06 |
| Review location | Disposable clone outside the project repository |
| Runtime | Python 3.11 or newer; standard-library runtime dependencies only |
| License | MIT |
| Credential use during review | None |
| Live myQ requests during review | None |
| Door commands during review | None |

The review covered the tracked files, full six-commit history, packaging metadata, installer, command entry points, OAuth implementation, HTTP transport, token storage, account and device discovery, physical command path, tests, CI workflow, secret-scanner baseline, file types, permissions, and repository metadata visible on GitHub.

## Provenance and supply-chain observations

- The repository was created in 2026, has one apparent maintainer, a short history, no tags or GitHub releases, two stars, and no forks at review time. This is limited provenance and offers little independent review.
- GitHub reported the current merge commit as verified. Two direct commits in the short history were unsigned. A verified merge commit establishes GitHub's record of that merge; it does not establish that the code is safe.
- The tree has no Git submodules or symbolic links. `git fsck --full --strict` completed successfully.
- No compiled executable was found. The only executable tracked file is `script/install`; the large binary asset is a documentation PNG.
- The package has no runtime dependency outside Python's standard library. This substantially reduces dependency confusion and transitive-package risk.
- The build requirement is an unbounded `setuptools>=77`; development dependencies use version ranges rather than a hash-locked environment. CI actions use mutable major-version tags. These are development and CI supply-chain weaknesses, although the planned direct-source execution avoids installing those dependencies.
- The declared package version is `0.2.0`, while `src/gatectl/__init__.py` reports `0.1.0`. This is a quality-control issue, not evidence of malicious behavior.

## Code and behavior observations

Positive controls found in the source include:

- No use of `subprocess`, `os.system`, `eval`, `exec`, `pickle`, dynamic module loading, or downloaded executable code.
- Standard Python TLS certificate verification is used by default.
- Network destinations are hard-coded to myQ service hosts and Google's Firebase App Check endpoint. No analytics, advertising, webhook, paste, or unrelated collection endpoint was found.
- Passwords and MFA codes are not written to the token store. Tokens and observations are atomically written with mode `0600` in a directory changed to mode `0700`.
- Write requests are limited to hard-coded garage-door `open` and `close` routes.
- The command path requires exactly one selected garage-door device, an online device, a known compatible state, and the relevant unattended-operation permission.
- Interactive operation requires typing the requested action unless `--yes` is supplied.
- Saved observations omit access and refresh tokens and redact serial numbers in the normal safe representation.

Hard-coded outbound hosts found in the reviewed source are:

- `partner-identity.myq-cloud.com`
- `accounts.myq-cloud.com`
- `devices.myq-cloud.com`
- `account-devices-gdo.myq-cloud.com`
- `firebaseappcheck.googleapis.com`

The Firebase API key, application identifier, and certificate fingerprint in the source are client metadata reverse-engineered from the Android flow, not user credentials. They remain interoperability constants that myQ can revoke, so the project must record their origin and never assume they are stable.

The Firebase App Check debug token is different. A debug token lets whoever holds it mint App Check tokens and bypass the attestation App Check exists to provide, so it is credential-like. Upstream published it, so this project treats it as compromised and keeps it out of the source; see GQ-07.

## Findings

### GQ-01: OAuth destinations are not constrained before secrets are posted

**Severity: high impact, defense-in-depth likelihood; release blocker.**

The login form action is resolved against the current page and receives the email address and password without checking the resulting scheme and origin. The MFA form action is handled similarly, and redirect navigation accepts arbitrary destinations. The custom callback is identified with a string-prefix comparison rather than an exact parsed scheme, host, and path comparison.

TLS protects against ordinary network interception, so exploiting this generally requires a compromised or malicious response in the trusted sign-in path, a server-side redirect or form-injection weakness, or a broken trust boundary. The consequence would be disclosure of the account password or MFA code to an unapproved host. Because these credentials can control a physical garage, the client must fail closed even under that abnormal condition.

Required remediation:

- Parse every navigation target and form action before use.
- Require HTTPS and an explicit allowlist of exact OAuth origins for any request carrying credentials, MFA, cookies, or consent fields.
- Strip sensitive headers when navigating between allowed origins unless they are explicitly required.
- Require an exact parsed match for the custom callback scheme, host, and path.
- Add negative tests for external origins, user-info tricks, deceptive suffixes, scheme downgrades, non-default ports, protocol-relative URLs, and callback-prefix confusion.

### GQ-02: Physical PUT requests are repeated after `401` or `403`

**Severity: medium; release blocker.**

The common request helper refreshes authentication and repeats the original request after either status. That behavior applies to `PUT .../open` and `PUT .../close`, and a unit test currently expects it. A `401` or `403` normally indicates that the rejected request was not accepted, but physical actions should not rely on that assumption or normalize automatic replay.

Required remediation:

- Refresh proactively before constructing a write request.
- Send a physical command at most once.
- On any response or network outcome that does not prove acceptance, re-fetch state and report uncertainty without replaying the PUT.
- Add tests proving zero automatic write retries for authentication failures, timeouts, disconnects, and malformed responses.

### GQ-03: State can change between confirmation and command

**Severity: medium; release blocker.**

The CLI fetches and validates a door, waits for the operator to type a confirmation, then sends a command using the earlier device object. Another control could change the door during that interval. The command helper validates the stale object but does not re-fetch the live door immediately before the PUT.

Required remediation:

- Store and select the target using account ID and door serial rather than display names.
- After confirmation, fetch the exact target again and repeat every online, family, state, fault, vacation, and unattended-operation check.
- Refuse to act if identity or state changed, the target is ambiguous, or the re-fetch fails.
- Add a regression test in which the door changes while confirmation is pending.

### GQ-04: HTTP response bodies are read without a size bound

**Severity: low.**

The HTTP layer calls `response.read()` with no upper bound. A malicious or malfunctioning endpoint could consume excessive memory. Add endpoint-appropriate limits and fail before parsing an oversized body.

### GQ-05: The installer is broader than this project needs

**Severity: low when avoided.**

`script/install` defaults to system-wide paths, clears its target virtual environment, installs the local package through pip, recursively changes permissions, and replaces a command symlink. No download command or privilege escalation was found, but its behavior is unnecessary for this personal project and broadens the failure surface.

Do not run the installer. Run the approved checkout directly with a supported Python interpreter and `PYTHONPATH=src`.

### GQ-06: Local path hardening and test coverage can improve

**Severity: low.**

Private atomic writes and restrictive modes are good controls. The storage layer does not explicitly verify directory ownership or reject an unsafe pre-existing directory. The test suite also lacks hostile OAuth-destination, filesystem, oversized-response, and ambiguous-write cases.

Use a newly created, user-owned mode-`0700` directory outside the repository, reject unsafe ownership or permissions, and add the missing negative tests.

### GQ-07: The App Check debug token is in the source

**Severity: medium for a public release.** Found 2026-10-07 during the public-release review.

Upstream `constants.py` hard-codes a Firebase App Check debug token, and the review above wrongly classified it as ordinary client metadata. Publishing it again would hand anyone a way to mint App Check tokens for myQ's Firebase project.

Remove it from the source and read it from local configuration that is never committed. Refuse sign-in with setup guidance, before any password prompt or request, when it is missing or malformed, and never echo the value.

## Checks performed

- Read every tracked source, configuration, workflow, installer, test, and documentation file relevant to execution.
- Searched for subprocess execution, dynamic evaluation and import, deserialization hazards, hidden network behavior, credential output, obfuscated Unicode, symbolic links, submodules, and unexpected executable files.
- Reviewed every hard-coded URL and each call site that sends an HTTP request.
- Reviewed password, MFA, access-token, refresh-token, observation, and target-config handling.
- Reviewed the guard and confirmation path for `open` and `close`.
- Inspected the complete commit history and GitHub repository metadata.
- Ran `git fsck --full --strict` successfully.
- Ran all 22 unit tests successfully with Python 3.13; the tests used local fakes and did not contact myQ.
- Ran Python bytecode compilation for `src` and `tests` successfully.
- Ran POSIX shell syntax validation for `script/install` successfully.

The existing CI reports successful runs and includes formatting, linting, secret scanning, shell syntax, and unit tests. Those results are supporting evidence only because the workflow dependencies are not pinned by immutable commit SHA and the current security findings are not covered by tests.

## Required approval checklist

The operational gate remains closed until all items below are complete:

- [x] Import the exact reviewed upstream commit into `vendor/gatectl` while preserving the MIT license and history or provenance record. See [gatectl-provenance.md](gatectl-provenance.md).
- [x] Implement GQ-01, GQ-02, and GQ-03. GQ-03's fault and vacation re-checks were missing at the first approval and were added on 2026-10-07.
- [x] Implement bounded HTTP response reads and private-directory ownership and permission checks.
- [x] Add all specified negative and physical-command regression tests.
- [x] Pin or otherwise reproducibly record the development and audit toolchain.
- [x] Run static checks, secret scan, full tests, compile check, and offline smoke test from a clean checkout. Locally on Python 3.13 and 3.14; CI covers 3.11 to 3.14.
- [x] Review the complete upstream-to-patched diff for scope and unexpected behavior.
- [x] Record the patched revision and confirm the worktree is clean. The tree hash identifies the reviewed code independently of later documentation commits.
- [x] Record an explicit approval with reviewer, date, residual risks, and expiration or re-review trigger. Recorded by the owner on 2026-10-06.

After approval, the first credential-bearing use must still use a hidden password prompt, isolated private paths, no installer, no `MYQ_PASSWORD`, no `--yes`, no logging of HTTP bodies, and physical supervision with an official control available.

## Re-review triggers

Repeat this review before use if any of the following changes:

- The gatectl commit or local patch changes.
- Any OAuth host, API host, redirect URI, Firebase constant, client identifier, app version, or request header changes.
- A runtime dependency or install step is added.
- The myQ login flow, MFA flow, token shape, command response, or door-state schema changes.
- A test unexpectedly reaches the network.
- myQ returns an unrecognized redirect, form action, state, status code, or response body.
- The repository or a secret scan shows an unexpected file, credential, binary, symlink, or generated artifact.

## Patched revision

Patched 2026-10-06 in `vendor/gatectl`. Every change is in `git diff <import commit> -- vendor/gatectl`; see [gatectl-provenance.md](gatectl-provenance.md).

| Item | Value |
| --- | --- |
| Upstream tree (import) | `4f4e91d825d91e094bb183df078975865a2dd9df` |
| Patched tree | `c1e3996937a493454dca51a7bd456d1490df2e05` (GQ-07; GQ-01 to GQ-06 unchanged from `e0eba7c2c8e20046914579f6d1d79efff403ce12`) |
| Previously approved trees | `e0eba7c2c8e20046914579f6d1d79efff403ce12` (pass of 2026-10-07, superseded by GQ-07) and `e200f354192ef179ad706809ed4f773e633623d9` (pass of 2026-10-06, superseded because GQ-03 was incomplete) |
| Verify | `git rev-parse HEAD:vendor/gatectl` must print the patched tree |

### Changes by finding

| Finding | Change | Regression tests (`tests/test_security.py`) |
| --- | --- | --- |
| GQ-01 | `_request_page` refuses every sign-in request that is not HTTPS to exactly `partner-identity.myq-cloud.com` on port 443 without user info. The callback must match scheme `com.myqops`, host `android` and an empty path exactly. | `OAuthDestinationTests`: hostile redirects, cross-origin login, MFA and consent forms, user-info tricks, deceptive suffixes, scheme downgrade, non-default port, protocol-relative, `javascript:` and `file:` URLs, callback-prefix confusion, and the exact callback |
| GQ-02 | Physical commands go through `_send_command_once`, which never refreshes and retries. Any transport error or non-2xx response raises `MyQCommandOutcomeUnknownError` ("it was not repeated"). The CLI then re-reads the door once and prints its state. The retrying read path refuses every method except GET. | `PhysicalCommandTests`: 401, 403, 429, 500, 302, timeout and connection reset each send exactly one PUT and no refresh; empty 2xx accepted; reads still refresh once. `test_unknown_outcome_reports_live_state_and_is_not_repeated` |
| GQ-03 | After confirmation the CLI re-fetches the door by account ID and serial, refuses if the name, state or online flag changed or the serial is missing or duplicated, and commands the re-fetched object. Since 2026-10-07 the command guard also refuses active faults, vacation mode for opening, and a present but malformed `active_fault_codes` or `in_vacation_mode`; an absent field means the opener does not report it, which is how the owner's openers behave. State polling also uses account ID and serial. The target config may pin `account_id` and per-device `serial`. | `ConfirmationRaceTests`: state change and rename while confirming, missing and duplicated serial, failed re-fetch, duplicate display names, serial and account-ID pins |
| GQ-04 | Response bodies are read with `read(limit + 1)` and refused above 1 MiB, for errors too. | `BoundedReadTests`, loopback server |
| GQ-05 | No code change. `script/install` stays unused. | Not applicable |
| GQ-06 | Token and observation directories and files must not be symlinks, must be owned by the current user and must have no group or other access; directory `chmod` failures are now errors. `OAuthTokens` reprs redact both tokens. | `PrivateStorageTests`, `SecretRedactionTests` |

Upstream tests changed, each for a stated reason:

- `test_client.test_command_retries_once_with_refreshed_token` asserted the unsafe GQ-02 retry; it is now `test_command_is_not_retried_with_refreshed_token`.
- `test_auth` fake responses used the host `https://identity`, which the GQ-01 allowlist refuses; they now use the real identity origin. Assertions are unchanged.
- `test_cli` fake clients gained one extra fetch for the GQ-03 re-fetch.

Behavior differences an operator will notice:

- Commands are always re-fetched before sending, including with `--yes`.
- While waiting for the terminal state, the CLI no longer rewrites the saved observation on every poll.
- A command with an unproven outcome exits with status 2 and prints the current state; repeat it only after checking the door.

### Checks run on the patched revision

| Check | Command | Result |
| --- | --- | --- |
| Offline tests (network blocked) | `script/gatectl-test` | 64 tests pass on Python 3.13.5 and 3.14.7, including `FaultAndVacationGuardTests` |
| Offline CLI smoke test | Part of `script/gatectl-test` | `--help`, `status`, `open`, `close --wait 500` and a missing config all exit as expected without network use |
| Mutation check | `script/gatectl_mutants.py` | 29 of 29 targeted mutants of the new guards are killed, six of them in the fault and vacation guard |
| Format and lint | `ruff format --check src tests`, `ruff check src tests` | Pass with ruff 0.16.10 |
| Secret scan, vendored tree | `git ls-files -z \| xargs -0 detect-secrets-hook --baseline .secrets.baseline` | Pass with detect-secrets 1.5.0; baseline unchanged |
| Secret scan, whole repository | `gitleaks git .` and `gitleaks dir .` | Pass with gitleaks 8.30.1; the four known findings are listed with reasons in `.gitleaksignore` |
| Bytecode compilation | `python -m compileall -q src tests` | Pass |
| CI | `.github/workflows/gatectl.yml` | Runs all of the above on Python 3.11, 3.12, 3.13 and 3.14 |

The network guard in `script/offline_unittest.py` blocks DNS and every non-loopback connection, and the run aborts if the guard fails to block myQ. No credential, live request or door command was used.

### Residual risks

- The myQ API, OAuth pages, Firebase App Check constants and client metadata are unsupported and can change without notice.
- The Firebase API key is third-party client metadata that myQ can revoke at any time.
- The App Check debug token is treated as compromised. It is kept out of the source, but any build that embeds it, including the owner's own app, carries an extractable copy. A public App Store release would need an authorized App Check path instead.
- `MYQ_PASSWORD` and `--yes` still exist in the CLI. The operational restrictions in PLAN.md forbid using them.
- An attacker able to alter TLS trust on the Mac, or to compromise `partner-identity.myq-cloud.com` itself, is outside what the allowlist can stop.
- A command can still be accepted by myQ and then fail at the door; the CLI distinguishes acceptance from the observed terminal state but cannot see the physical door.
- The patches have only been tested with fakes. The first live login and supervised door cycle in Phase 2 are the real-world check.

## GQ-07 revision

Prepared 2026-10-07 for GQ-07. The owner recorded **pass** for this tree on 2026-10-07; see the [approval record](#approval-record).

| Item | Value |
| --- | --- |
| Approved tree | `c1e3996937a493454dca51a7bd456d1490df2e05` |
| Based on | Approved tree `e0eba7c2c8e20046914579f6d1d79efff403ce12` |
| Verify | `git rev-parse HEAD:vendor/gatectl` |

Changes:

- `constants.py` no longer contains the debug token. It defines `APP_CHECK_DEBUG_TOKEN_ENV = "GATECTL_APP_CHECK_DEBUG_TOKEN"` instead.
- `auth.require_app_check_debug_token()` reads that variable, trims it, requires the 8-4-4-4-12 hexadecimal shape, and raises `MyQApiError` without echoing the value. `MyQLoginSession.start` and the CLI's `login` call it before the password prompt or any request; the App Check exchange posts the configured value.
- Refresh, status and door commands do not need the token and are unchanged.
- `script/gatectl_session.py` (outside the vendored tree) sets the variable from `MYQ_APP_CHECK_DEBUG_TOKEN` in the ignored `config/MyQ.local.xcconfig`, the same file Xcode includes. It ignores an inherited value and refuses a symlinked config file.
- Tests: `AppCheckConfigurationTests` (missing, blank, malformed, unexpanded and over-long values; nothing sent before the refusal), `LoginConfigurationTests` (no password prompt without the token), and the MFA login test now asserts the configured value is posted. Login tests use a fabricated token.
- `.secrets.baseline`: the certificate fingerprint finding moves from line 27 to line 28; no new findings.

| Check | Result |
| --- | --- |
| `script/gatectl-test` (network blocked) | 68 tests pass on Python 3.14 |
| Session wrapper tests | 17 pass |
| `script/gatectl_mutants.py` | 29 of 29 killed |
| `ruff format --check`, `ruff check` (0.16.10) | Pass |
| `detect-secrets-hook --baseline .secrets.baseline` (1.5.0) | Pass |
| `python -m compileall -q src tests` | Pass |

## Approval record

The agent may recommend; only the owner decides.

| Field | Value |
| --- | --- |
| Reviewed revision | `vendor/gatectl` tree `c1e3996937a493454dca51a7bd456d1490df2e05` |
| Agent review | Claude (AI coding agent), 2026-10-06, re-reviewed 2026-10-07 after the GQ-03 finding and again for GQ-07 |
| Agent recommendation | **Pass** for supervised Phase 2 use under the PLAN.md operational restrictions, with the residual risks above |
| Owner reviewer | Brian Batt |
| Owner decision | **pass** |
| Decision date | 2026-10-07 |
| Expires | On any re-review trigger above, or 2027-01-05 (90 days after the decision date), whichever comes first |

History: the owner recorded **pass** on 2026-10-06 for tree `e200f354192ef179ad706809ed4f773e633623d9`, superseded on 2026-10-07 because GQ-03 lacked the fault and vacation re-checks; then **pass** on 2026-10-07 for tree `e0eba7c2c8e20046914579f6d1d79efff403ce12`, superseded the same day by the GQ-07 change; then **pass** on 2026-10-07 for tree `c1e3996937a493454dca51a7bd456d1490df2e05`.

Phase 2 may continue under the PLAN.md operational restrictions, through `script/gatectl_session.py`. Physical door commands always require a person watching the door and an official control at hand.
