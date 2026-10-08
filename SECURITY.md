# Security policy

This app can open and close real garage doors, so security reports matter here.

## Never post secrets or home details publicly

Do not include any of the following in an issue, pull request, discussion, or comment:

- myQ email addresses, passwords, MFA codes, access tokens, or refresh tokens;
- the Firebase App Check debug token from `config/MyQ.local.xcconfig`;
- door serial numbers, account IDs, door or home names, addresses, or photos of your home.

If you posted any of these by mistake, change your myQ password, and tell the maintainer privately so the post can be removed.

## Reporting a vulnerability

Report privately through GitHub's [private vulnerability reporting](https://github.com/elearningplugins/whisper-lift/security/advisories/new) ("Report a vulnerability" on the Security tab). Do not open a public issue.

Include the affected file or feature, the steps to reproduce with fabricated values, and the impact you expect. A door command that runs without the confirmation and safety checks is the most serious class of report.

## What to expect

This is a personal project maintained by one person. Reports are read and handled as soon as practical, with no promised response times. You'll be told when a report is confirmed and when a fix lands. Credit is given in the advisory unless you ask not to be named.

## Supported versions

There are no releases. Only the latest commit on `main` is supported.

## Scope

**In scope:**

- the iOS app and its Siri intents;
- `GarageDoorKit`;
- the scripts in `script/`;
- the security patches to `vendor/gatectl`.

**Out of scope:**

- **myQ and Chamberlain services.** Report those to Chamberlain Group.
- **Unpatched upstream gatectl.** Report those upstream as well.
