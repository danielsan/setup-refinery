# Security policy

## Reporting a vulnerability

Please report security issues privately via
[GitHub Security Advisories](https://github.com/danielsan/setup-refinery/security/advisories/new)
rather than opening a public issue.

Include the action version or commit SHA, the runner OS, and the steps to reproduce. Expect an
initial response within a few working days.

If the issue is in refinery itself rather than in this action's packaging or installation, please
report it to [rust-db/refinery](https://github.com/rust-db/refinery) — this repository only compiles
and distributes their CLI.

## What this action guarantees

- Every downloaded archive is verified against a published SHA-256 checksum before anything is
  installed. Verification **cannot** be disabled, and a mismatch aborts the step.
- Binaries are built only from the crates.io source tarball for the requested version, whose
  checksum is verified against the crates.io API before the build starts.
- Release assets carry build provenance attestations, verifiable with
  `gh attestation verify <asset> --repo danielsan/setup-refinery`.
- No telemetry, and no network access beyond GitHub releases (plus crates.io if you opt into
  `fallback: cargo`).

## Supported versions

Security fixes land on the latest `v1.x` release, which the moving `v1` tag tracks.

## Hardening advice

Pin to a full commit SHA rather than a moving tag:

```yaml
- uses: danielsan/setup-refinery@<full-sha> # v1.0.0
```

Pinning an exact refinery `version` as well means the action makes no GitHub API calls at all.
