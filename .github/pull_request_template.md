## Summary

<!-- What changed, concretely. -->

## Why

<!-- The problem, the verified root cause, the intended behavior, and the non-goals. -->

## Lines of code

<!-- Per-file rows from `git diff --numstat origin/main...HEAD`; never one combined number for production and tests. -->

| Category | File | + | − |
|---|---|---:|---:|
| Fix | `path` | 0 | 0 |
| **Fix subtotal** | | **0** | **0** |
| Fix (config) | `path` | 0 | 0 |
| **Fix (config) subtotal** | | **0** | **0** |
| Tests | `path` | 0 | 0 |
| **Tests subtotal** | | **0** | **0** |
| **Total** | | **0** | **0** |

## Automated testing

<!-- The exact commands and their results (counts, sanitizers, mutation results); say which checks you did not run. -->

## Physical-device testing

<!-- What a person observed on an iPhone or a real door, with the date, the iOS version and the opener; write "None" if nothing was tested on a device. -->

## Review questions

1. Does this change existing behavior, or is it additive?
2. What is the performance and network impact (requests, bytes, latency)?
3. What could still be wrong here?
4. What else changed that is not obvious?
5. Which adjacent behavior shares this code path: Siri intents, the door cards, Settings, the status checks, the token refresh, gatectl?
6. Does this touch door commands, safety checks, sign-in, tokens, hosts, or `vendor/gatectl`? If so, how is that covered?

## Known limitations and unverified assumptions

<!-- What remains untested, deferred, or assumed. -->

## Checklist

- [ ] Tests were written first and fail without the change
- [ ] Only fabricated data appears in tests, logs and screenshots
- [ ] No secrets, signing material or local configuration are committed
- [ ] Every code comment is a single line
- [ ] Docs are updated where behavior changed
