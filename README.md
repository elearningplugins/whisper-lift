# Whisper Lift

A personal iPhone app ("Whisper Lift", internally `GarageTiles`) that opens and closes two myQ garage doors by Siri, with the iOS 26 CarPlay widgets page as a secondary goal. The design and phases are in [PLAN.md](PLAN.md).

> **Safety:** this app can move real garage doors. Its door cards, `OpenDoorIntent` and `CloseDoorIntent` send live myQ commands once you sign in, including from Siri while the iPhone is locked. Test only with a person watching the door and the wall control in reach. The spike counter widget is the only part that uses a mock counter.

## Status

- **Phase 0 (feasibility spike):** the counter spike lives on in the spike widget; its app tab was removed on 2026-10-07. CI builds the app for iOS 26 and runs Simulator UI tests. On 2026-10-07 the app was signed with the free Personal Team (App Group and Keychain group accepted, check A3) and installed on an iPhone running iOS 26. See [docs/phase-0-spike.md](docs/phase-0-spike.md).
- **Phase 1 (gatectl security gate):** see the approval record in [docs/gatectl-security-review.md](docs/gatectl-security-review.md); the Mac session wrapper refuses to run unless it records an owner pass for the current `vendor/gatectl` tree.
- **Phase 2 (Mac sessions):** the Mac session exists and one door has been cycled under supervision. The phone-seed session was imported into the iPhone app on 2026-10-07 and its Mac copy deleted. The app now also has its own "Sign in with myQ" flow, so new sessions no longer need a token paste; see [PLAN.md](PLAN.md#in-app-sign-in).
- **Phases 4–8:** door, token and myQ logic in `GarageDoorKit`, wired into the app's Doors tab and the Siri intents. See [docs/garage-door-kit.md](docs/garage-door-kit.md).

## Next steps for the owner

1. Test Siri, supervised: *"close small door with Whisper Lift"*, unlocked, locked, then in the car. Siri routes phrases containing "garage" to Apple Home, so use the door nicknames.
2. Reinstall from Xcode before the free signing profile expires every seven days.

## Limits

- **Not for App Store or public distribution.** Sign-in relies on a Firebase App Check debug token that the build places in the app's Info.plist, where anyone with the app could extract it. Firebase says debug tokens must never ship in production apps. A distributable version would need an authorized production sign-in path from Chamberlain; no configuration trick can make a static secret safe inside an iPhone app.
- **Sign-in needs local configuration this project doesn't provide.** See [CONTRIBUTING.md](CONTRIBUTING.md). Without it the app builds and runs, but can't sign in.

## Tests

```sh
script/test       # Swift Testing suite, including seeded property tests
script/typecheck  # type-checks the app and widget sources without Xcode
```

## License, trademarks and policies

Code written for this repository is under the [MIT License](LICENSE). `vendor/gatectl` keeps its own MIT license; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The license covers this code only. It grants no access to Chamberlain Group's or myQ's services and no right to use their trademarks.

**Not affiliated with, endorsed by, or sponsored by Chamberlain Group, myQ, or Apple.** myQ, Chamberlain and LiftMaster are trademarks of The Chamberlain Group LLC. The app uses an undocumented myQ API that can stop working at any time.

- [CONTRIBUTING.md](CONTRIBUTING.md): setup, checks, and pull request expectations
- [SECURITY.md](SECURITY.md): private vulnerability reporting, and what never to post publicly
- [PRIVACY.md](PRIVACY.md): what the app stores and which hosts it contacts
