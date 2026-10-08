# Third-party notices

The root [LICENSE](LICENSE) (MIT) covers the code written for this repository. It does not cover the third-party code below, which keeps its own license. It grants no rights to Chamberlain Group's or myQ's services, APIs, or trademarks.

## gatectl

| Item | Value |
| --- | --- |
| Location | `vendor/gatectl` |
| Upstream | https://github.com/cnberry/gatectl |
| Upstream commit | `47ef70d368f557d496331d51a3c65576bca05bda` |
| License | MIT, Copyright (c) 2026 Chris Berry; full text in [`vendor/gatectl/LICENSE`](vendor/gatectl/LICENSE) |
| Its own notice | [`vendor/gatectl/NOTICE.md`](vendor/gatectl/NOTICE.md) |

This repository changes gatectl with local security patches GQ-01 to GQ-07:

- an OAuth origin allowlist and exact callback matching;
- no automatic retry of physical door commands;
- re-fetching and re-checking the door after confirmation, including faults and vacation mode;
- bounded response reads;
- private-storage checks;
- reading the App Check debug token from local configuration instead of the source.

Each change and its tests are listed in [`docs/gatectl-security-review.md`](docs/gatectl-security-review.md). How the import was done and how to verify it is in [`docs/gatectl-provenance.md`](docs/gatectl-provenance.md).

## myq-home-assistant (via gatectl)

gatectl adapts the myQ form parsing, OAuth sequence, client metadata, and residential endpoint research from https://github.com/bvdcode/myq-home-assistant (MIT License, Copyright (c) 2026 Vadim Belov). The Swift client in `GarageDoorKit` reimplements the same protocol from gatectl's code: the endpoints, the client metadata in `MyQMetadata.swift`, and the sign-in sequence in `MyQSignIn.swift`. The full license text is reproduced in [`vendor/gatectl/NOTICE.md`](vendor/gatectl/NOTICE.md).

## Atkinson Hyperlegible Next

| Item | Value |
| --- | --- |
| Location | `ios/GarageTiles/GarageTiles/Fonts` (Regular, SemiBold and Bold, unmodified) |
| Upstream | https://github.com/googlefonts/atkinson-hyperlegible-next |
| License | SIL Open Font License 1.1, Copyright 2020-2024 The Atkinson Hyperlegible Next Project Authors; full text in [`OFL-AtkinsonHyperlegibleNext.txt`](ios/GarageTiles/GarageTiles/Fonts/OFL-AtkinsonHyperlegibleNext.txt) |

The app design uses this typeface, made by the Braille Institute for low-vision readers.

## Trademarks

myQ, Chamberlain, and LiftMaster are trademarks of The Chamberlain Group LLC. Apple, iPhone, Siri, and CarPlay are trademarks of Apple Inc. This project is not affiliated with, endorsed by, or sponsored by Chamberlain Group, myQ, or Apple. Names are used only to describe compatibility.
