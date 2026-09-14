# Setup refinery CLI

[![CI](https://github.com/danielsan/setup-refinery/actions/workflows/ci.yml/badge.svg)](https://github.com/danielsan/setup-refinery/actions/workflows/ci.yml)
[![Marketplace](https://img.shields.io/badge/marketplace-setup--refinery-blue?logo=github)](https://github.com/marketplace/actions/setup-refinery-cli)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Install the [refinery](https://github.com/rust-db/refinery) SQL migration CLI on a GitHub Actions
runner and add it to `PATH` — **in about a second**. Measured on the hosted runners: 1s on Linux
x64/arm64 and macOS arm64, 3s on Windows, 7s on the Intel macOS runner.

Prebuilt, checksum-verified binaries for Linux, macOS and Windows (x64 and arm64). No Docker, no
`cargo install`, no Rust toolchain required.

> **Why this exists.** Upstream stopped publishing prebuilt binaries: refinery `v0.9.0`–`v0.9.2`
> have zero release assets. Their release workflow triggers on tags matching
> `[0-9]+.[0-9]+.[0-9]+`, but from 0.9.0 their tags gained a `v` prefix, so it never fires. Without
> this action your only option is `cargo install refinery_cli` — three to ten minutes of compilation
> on every single CI run.

## Quick start

```yaml
- uses: danielsan/setup-refinery@v1
  with:
    version: '0.9.2'

- run: refinery migrate -e DATABASE_URL -p ./migrations
  env:
    DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

Pinning an exact `version` is recommended: it makes your builds reproducible **and** skips the
GitHub API entirely, so the action can never be affected by API rate limits.

> ### Using a coding agent?
>
> Point it at **[docs/for-coding-agents.md](docs/for-coding-agents.md)** — a dense, verified
> reference covering the `refinery` CLI's real behaviour: that `-e` takes an environment variable
> *name* rather than a URL, the exact migration filename rules (and which mistakes fail silently
> versus abort the whole run), why timestamp-style versions overflow, and the flags that matter in
> CI. Every claim there is checked against a real binary. It ends with a block you can paste into
> your own repository's `AGENTS.md`.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `version` | `latest` | `latest`, an exact version (`0.9.2` or `v0.9.2`), or a partial version (`0.9` → newest 0.9.x). Semver ranges such as `^0.9` are **not** supported. |
| `token` | `${{ github.token }}` | Used only to look up releases for `latest`/partial versions. An exact version makes no API call at all. Supply a PAT if your runners share an egress IP and hit the 60 requests/hour unauthenticated limit. |
| `fallback` | `none` | What to do when no prebuilt binary matches. `none` fails fast and lists what is available. `cargo` compiles via `cargo install refinery_cli` — 3–10 minutes of billed CI time, and requires a Rust toolchain already on `PATH`. |

## Outputs

| Output | Description |
| --- | --- |
| `version` | The exact version installed, without a leading `v` (e.g. `0.9.2`). |
| `bin-path` | Absolute path to the executable, in native path form (includes `.exe` on Windows). |
| `cache-hit` | `true` if the binary came from the runner tool cache and nothing was downloaded. |

## Supported platforms

| Runner | Architecture | Target |
| --- | --- | --- |
| `ubuntu-*` | x64 | `x86_64-unknown-linux-musl` |
| `ubuntu-*-arm` | arm64 | `aarch64-unknown-linux-musl` |
| `macos-latest`, `macos-14`+ | arm64 | `aarch64-apple-darwin` |
| `macos-15-intel`, `macos-13` | x64 | `x86_64-apple-darwin` |
| `windows-*` | x64 | `x86_64-pc-windows-msvc` |
| `windows-11-arm` | arm64 | runs the x64 binary under Windows' x64 emulation (with a warning) |

The Linux binaries are **statically linked against musl**, so they run on Alpine and on any glibc
vintage — no `GLIBC_2.xx not found` failures in slim containers.

Not prebuilt: 32-bit ARM Linux and 32-bit x86 Linux. On those, use `fallback: cargo`.

## Examples

<details>
<summary>Migrate a Postgres service container</summary>

```yaml
jobs:
  migrate:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:17-alpine
        env:
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: app
        ports: ['5432:5432']
        options: >-
          --health-cmd "pg_isready -U postgres" --health-interval 5s
          --health-timeout 5s --health-retries 10
    env:
      DATABASE_URL: postgres://postgres:postgres@localhost:5432/app
    steps:
      - uses: actions/checkout@v5
      - uses: danielsan/setup-refinery@v1
        with:
          version: '0.9.2'
      # No refinery.toml needed: with -e, the database type comes from the URL scheme.
      - run: refinery migrate -e DATABASE_URL -p ./migrations
```

Service containers are only available on Linux runners — hosted macOS has no Docker and Windows
does not support them.
</details>

<details>
<summary>Cross-platform matrix</summary>

```yaml
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest, windows-latest]
runs-on: ${{ matrix.os }}
steps:
  - uses: danielsan/setup-refinery@v1
    with:
      version: '0.9.2'
  - run: refinery --version
```
</details>

<details>
<summary>Monorepo with a config file</summary>

```yaml
- uses: danielsan/setup-refinery@v1
  with:
    version: '0.9.2'
- run: refinery migrate -c ./services/billing/refinery.toml -p ./services/billing/migrations
```

Keep the `./` on the config path — see [Troubleshooting](#troubleshooting).
</details>

<details>
<summary>Build from source on an unsupported platform</summary>

```yaml
- uses: dtolnay/rust-toolchain@stable
- uses: danielsan/setup-refinery@v1
  with:
    version: '0.9.2'
    fallback: cargo
```
</details>

<details>
<summary>Self-hosted runners behind a shared IP</summary>

```yaml
- uses: danielsan/setup-refinery@v1
  with:
    version: 'latest'
    token: ${{ secrets.READ_ONLY_PAT }}
```

Or simply pin an exact version, which makes no API call at all.
</details>

## What this action does and does not do

**It installs refinery and gets out of the way.** It does not run your migrations. A plain
`- run: refinery migrate ...` step is clearer than any set of inputs we could invent, keeps every
CLI flag available to you immediately, and means we never handle your database credentials.

**It does not use `actions/cache`.** The download is 1–3 seconds; the cache round trip costs 2–5
seconds *even on a hit*, plus a save on every miss. It would make things slower. The action does
consult the runner tool cache, which is free, so two `uses:` in the same job download once.

## Which refinery features are compiled in

Built with refinery's **default features**: `mysql`, `postgresql`, `sqlite-bundled`, `mssql`.

- **`int8-versions` is OFF.** Migration versions are `i32` and `refinery_schema_history` has
  standard semantics. Builds using `--all-features` (including upstream's own release workflow)
  differ here, which changes that table.
- **SQLite is bundled** and compiled with `SQLITE_ENABLE_MATH_FUNCTIONS`, matching upstream.
- **Postgres TLS is opt-in** via `?sslmode=require` in your connection URL. It uses OpenSSL on
  Linux, SChannel on Windows and Security.framework on macOS. It requires **refinery 0.9.2 or
  later** — upstream 0.9.0 and 0.9.1 compile the `postgresql` feature against a driver with no TLS
  backend, so those binaries cannot do `sslmode=require` at all. We publish them for completeness
  and label it in each archive's `BUILDINFO.txt`.
- **MSSQL connections are not encrypted**, and Windows integrated auth is unavailable: upstream
  builds `tiberius` with `default-features = false`, which disables its TLS backend. This is
  upstream's choice, not ours.

## Security

- Every download is verified against a published SHA-256 checksum. **Verification cannot be
  disabled**, and a mismatch aborts without installing anything.
- Binaries are compiled by [`build-upstream.yml`](.github/workflows/build-upstream.yml) from the
  crates.io source tarball, whose checksum is verified against the crates.io API before building.
  Each archive contains a `BUILDINFO.txt` recording the upstream commit, the exact compiler and
  cargo invocation, and every deviation from a plain `cargo install`.
- Releases carry [build provenance attestations](https://docs.github.com/actions/security-guides/using-artifact-attestations).
  Verify one with:
  ```bash
  gh attestation verify refinery-0.9.2-x86_64-unknown-linux-musl.tar.gz --repo danielsan/setup-refinery
  ```
- `permissions: contents: read` is sufficient for consumers.
- For `step-security/harden-runner` users, the egress allowlist is `github.com`, `api.github.com`
  and `objects.githubusercontent.com` — plus `static.crates.io` and `index.crates.io` only if you
  enable `fallback: cargo`.
- Pin to a commit SHA if you want maximum supply-chain assurance:
  `uses: danielsan/setup-refinery@<sha> # v1.0.0`.

## Versioning

- **`@v1`** — a moving tag that tracks the latest v1.x. Recommended.
- **`@v1.0.0`** — an exact action release, for reproducibility.
- **`refinery-v*`** tags (e.g. `refinery-v0.9.2`) are **binary payloads, not action versions.**
  Never use them in `uses:`; pin `@v1` or `@v1.2.3`.

New refinery versions do not require a new action release: `version: latest` resolves at runtime, so
a newly published binary is picked up immediately.

## Troubleshooting

**`GitHub API rate limit exhausted`** — pass `token: ${{ github.token }}` (1000 requests/hour per
repo) or pin an exact version, which makes no API call at all.

**`no prebuilt refinery binary for version X`** — the error lists the versions that do have an asset
for your platform. Pin one of those, or use `fallback: cargo`.

**`refinery_cli had a problem and crashed` when using `-c`** — keep the `./` on the config path.
Use `-c ./refinery.toml`, not `-c refinery.toml`. This is an
[upstream bug](https://github.com/rust-db/refinery/blob/main/refinery_core/src/config.rs): for a
bare filename, `Path::parent()` returns `Some("")` rather than `None`, so refinery tries to
canonicalize an empty path and panics. It only affects the SQLite driver. The CLI's own default
(`./refinery.toml`) is unaffected.

**`refinery --version` prints `refinery_cli 0.9.2`** — that is expected. The crate is `refinery_cli`
and the binary is `refinery`.

**Alpine or slim containers** — the Linux binaries are static and need no glibc. But note that
running the *action itself* inside a `container: alpine` job does not work: composite actions
require `bash`, which Alpine lacks. Install on the host job and pass the binary in, or use a
container image that includes bash.

**`checksum mismatch`** — the action retries once, then fails without installing. Usually a
truncated transfer or an interfering proxy. Please open an issue if it reproduces.

## More documentation

| Document | Audience |
| --- | --- |
| [docs/for-coding-agents.md](docs/for-coding-agents.md) | AI coding agents, and anyone debugging refinery CLI behaviour |
| [AGENTS.md](AGENTS.md) | Contributors and agents working **on this repository** |
| [RELEASING.md](RELEASING.md) | Maintainers cutting a release |
| [SECURITY.md](SECURITY.md) | Reporting a vulnerability |

## Comparison

| | this action | [WalletConnect/refinery-action](https://github.com/WalletConnect/refinery-action) | `cargo install refinery_cli` |
| --- | --- | --- | --- |
| Time per run | ~2 s | Docker image build/pull | 3–10 min |
| Platforms | Linux, macOS, Windows (x64 + arm64) | Linux only (Docker action) | any with a Rust toolchain |
| Checksum verified | yes | no | crates.io checksum |
| Build provenance | yes | no | no |
| Maintained | yes | last updated 2023 | — |

## Licence

The action is MIT licensed — see [LICENSE](LICENSE).

It redistributes **compiled binaries** of `refinery_cli`, which is licensed `MIT OR Apache-2.0`;
these are redistributed under the MIT option. Each release archive includes upstream's `LICENSE` and
a `THIRD-PARTY-NOTICES.md` covering the statically linked dependencies. See [NOTICE](NOTICE).

Not affiliated with or endorsed by the refinery maintainers.
