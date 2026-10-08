# Privacy

Whisper Lift has no server, analytics, telemetry, crash reporting, or advertising. It talks only to myQ and, during sign-in, to Google's Firebase App Check.

## What the app stores, and where

| Data | Where | Notes |
| --- | --- | --- |
| myQ access and refresh token | iOS Keychain, in the app's shared access group | Available after first unlock, this device only, never synced to iCloud. Siri and the widget read it from the same group. |
| Door list: account ID, account name, door serial numbers, door names, Siri nicknames | App Group container | Used to match Siri phrases and show the Doors tab. |
| Last known door state, and the time and result of the last command | App Group container | Shown on the Doors tab and the widget. |
| myQ request log: time, method, host, endpoint, status, estimated byte counts | App Group container, last 500 requests | Endpoints are stored as templates, with `{account}` and `{serial}` in place of the IDs. Bodies, headers and tokens are never logged. **Export request log (JSON)** on the Doors tab shares it. |

The app never sees your myQ password or MFA code. **Sign in with myQ** opens myQ's own page in an ephemeral system browser session, which keeps no cookies afterwards, and the app receives only the resulting session.

## Network endpoints

All requests use HTTPS, follow no redirects, and keep no cookies or cache.

| Host | Purpose |
| --- | --- |
| `partner-identity.myq-cloud.com` | Sign-in page, token exchange, token refresh |
| `accounts.myq-cloud.com` | List your myQ accounts |
| `devices.myq-cloud.com` | Read door state: one request per account when the app opens, returns to the foreground or is pulled down, and before each command |
| `account-devices-gdo.myq-cloud.com` | Open and close commands |
| `firebaseappcheck.googleapis.com` | One App Check exchange at sign-in |

Requests to any other host are refused in code.

## Signing out and deleting data

- **Sign out** on the Doors tab deletes everything the app saved on the iPhone: the token, the door list, the last door states and the request log. It removes the token first, so nothing can act while it finishes. If a door command is still running, it waits for that command and tells you to tap **Sign out** again. Siri, the widget, and the app stop working until you sign in again.
- Deleting the app removes its App Group data. iOS can keep Keychain items after an app is deleted, so tap **Sign out** first.
- To end the session on myQ's side too, change your myQ password or sign out of all devices in the myQ app.

## Mac tools

`script/gatectl_session.py` runs the vendored `gatectl` for supervised diagnostics. It keeps its tokens and state in `~/.config/myq-carplay/` with owner-only permissions (`0700` directory). It reads the App Check debug token from `config/MyQ.local.xcconfig`, which is ignored by git. Delete those files to remove the Mac session.
