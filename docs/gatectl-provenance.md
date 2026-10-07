# gatectl provenance

| Item | Value |
| --- | --- |
| Upstream | https://github.com/cnberry/gatectl |
| Upstream commit | `47ef70d368f557d496331d51a3c65576bca05bda` |
| Upstream tree | `4f4e91d825d91e094bb183df078975865a2dd9df` |
| License | MIT (`vendor/gatectl/LICENSE`, third-party notice in `vendor/gatectl/NOTICE.md`) |
| Import date | 2026-10-06 |
| Import method | `git clone` into a disposable directory, `git fsck --full --strict`, then `git archive 47ef70d… \| tar -x -C vendor/gatectl` |
| Import commit in this repository | The commit titled "Import gatectl 47ef70d verbatim into vendor/gatectl" |

## Verifying the import

The import commit's `vendor/gatectl` tree is byte-identical to the upstream commit's root tree. Check it with:

```sh
git rev-parse "<import commit>:vendor/gatectl"   # must print 4f4e91d825d91e094bb183df078975865a2dd9df
```

Every later change under `vendor/gatectl` is a local patch. Review the complete upstream-to-patched diff with:

```sh
git diff "<import commit>" -- vendor/gatectl
```

Do not merge future upstream changes silently. Each update starts a new security review.
