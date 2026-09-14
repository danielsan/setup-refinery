# AGENTS.md

Guidance for any coding agent (Claude Code, Codex, Cursor, Copilot, Gemini CLI, …) working **on
this repository**. Human contributors should read it too.

> **Looking to _use_ this action in another project?** You want
> [`docs/for-coding-agents.md`](docs/for-coding-agents.md) instead — that is the consumer-facing
> reference for wiring refinery migrations into a workflow. This file is about developing the action
> itself.

## What this repository is

`setup-refinery` — a **GitHub Action that installs the [`refinery`](https://github.com/rust-db/refinery)
SQL migration CLI onto a CI runner** and puts it on `PATH`, so other repositories can run database
migrations in their own pipelines with one `uses:` step.

This repo is *not* a fork of refinery and contains no migration logic. It has two independent halves,
which fail for different reasons — keep them separate in your head:

1. **The release pipeline** (`.github/workflows/build-upstream.yml`) compiles `refinery_cli` from
   crates.io for five runner platforms and publishes the binaries as release assets **of this repo**.
   It breaks on *toolchain* problems: cross-compilation, C dependencies, TLS.
2. **The action** (`action.yml` + `scripts/`) downloads the right asset, verifies it, and adds it to
   `PATH`. It breaks on *runner* problems: platform detection, cache keys, PATH, missing assets.

Consumer contract — install only. We never run migrations for the user:

```yaml
- uses: danielsan/setup-refinery@v1
  with:
    version: '0.9.2'
- run: refinery migrate -e DATABASE_URL -p ./migrations
  env:
    DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

### Why it exists

Upstream stopped shipping prebuilt binaries: tags `v0.9.0`–`v0.9.2` have **zero** release assets,
while `0.8.14` and earlier had 3–6. Root cause: upstream's `releases.yml` triggers on
`push: tags: ["[0-9]+.[0-9]+.[0-9]+"]`, but from 0.9.0 their tags gained a `v` prefix, so the
workflow never fires. Consumers must therefore `cargo install refinery_cli` — minutes per CI run for
something that should be one static binary.

## Repo layout

```
action.yml                  # root — Marketplace requires exactly this location
.github/targets.json        # SHARED target→runner→ext map, read by BOTH halves
scripts/lib.sh              # pure helpers (version, platform, paths, checksums)
scripts/setup.sh            # resolve → download → verify → extract → PATH
scripts/verify.sh           # runs in a SEPARATE step; proves PATH actually works
```

Logic lives in `scripts/*.sh`, never inlined in YAML — so `shellcheck`/`actionlint` can analyse it,
tests can cover it, and the five matrix legs cannot diverge. Invoke as
`bash "$GITHUB_ACTION_PATH/scripts/setup.sh"`: via `bash` so a lost executable bit can't break
consumers, and via the **env var** rather than `${{ github.action_path }}` (actions/runner#2185).

`.github/targets.json` is deliberately shared by producer and consumer so an asset name can never
drift between the two. `runner` is data, not baked into YAML, so a retired runner label is a
one-line change.

## Verified upstream facts

Pinned to upstream `v0.9.2` (commit `e028287bea12296b34f0fb679ff07aa33c53e115`). Re-verify when
bumping.

- Crate `refinery_cli` → **binary named `refinery`**. They differ.
- **`refinery --version` prints `refinery_cli 0.9.2`, not `refinery 0.9.2`.** Verified on a built
  binary. Never assert exact equality against `refinery <version>`; substring-match the version.
- Default features: `mysql`, `postgresql`, `sqlite-bundled`, `mssql`.
- Two subcommands only:
  - `refinery setup` — interactive, writes `refinery.toml`. **Useless in CI; never expose it.**
  - `refinery migrate` — `-c <config>` (default `./refinery.toml`), `-p <path>` (default
    `./migrations`), `-e <ENV_VAR>`, `-g` grouped, `-f` fake, `-t <target>`, `-d` divergent,
    `-m` missing, `--table-name` (default `refinery_schema_history`).
- **`-e` and `-c` are mutually exclusive.** `migrate.rs:108-114`: given `-e`, the config file is
  never read, and `db_type` comes from the URL scheme. So `refinery migrate -e DATABASE_URL -p ./migrations`
  needs **no `refinery.toml`** — verified end to end on a real binary.
- Upstream tags are unsortable garbage (`0.10`, `0.4`, `0.3`, `0.2` mixed with `v0.9.2`). **Use
  crates.io, never git tags**, for version discovery: clean semver, plus yank status
  (`0.8.15` is yanked; git cannot tell you that). crates.io requires a `User-Agent` or returns empty.

### Migration version constraints (verified on a real binary)

`SchemaVersion` is `i32` (`refinery_core/src/util.rs:11`, `#[cfg(not(feature = "int8-versions"))]`),
and the filename stem regex is `^([U|V])(\d+(?:\.\d+)?)__(\w+)`. The regex is looser than the
parser, which produces two different failure modes:

- A name that does not match the regex is **silently skipped** — no warning, exit 0.
- A name that matches but whose version is not a valid `i32` is a **hard error that aborts the whole
  run**, including migrations that would otherwise apply. Both `V1.1__x.sql` (the regex permits a
  decimal that the parser rejects) and `V20260914120000__x.sql` (i32 overflow) fail this way.
  `V2147483647__x.sql` is the largest that works.

Keep `test/migrations/` fixtures to plain sequential integers.

### Upstream bug to know about

**`-c refinery.toml` panics with SQLite; `-c ./refinery.toml` works.** `refinery-core/src/config.rs:89`
does `canonicalize(config_db_dir).unwrap()`, and for a bare filename `Path::parent()` returns
`Some("")` rather than `None` — so the `unwrap_or(current_dir)` guard never fires and canonicalizing
`""` panics with `NotFound`. The CLI's *default* (`./refinery.toml`) is safe. Only affects the Sqlite
path. Document it in troubleshooting; do not try to work around it in the action.

### Feature-flag traps

- **Never `--all-features`.** It enables `int8-versions`, which switches migration versions to `i64`
  and changes `refinery_schema_history` semantics. Upstream's own release workflow does this — do not
  copy it. A `cargo tree -e features` assertion in every build job guards this.
- **rustls is not an option.** `refinery_core/src/drivers/config.rs:107-111` *panics* in the sync
  Postgres path — the one `refinery migrate` uses — when TLS is requested under
  `tokio-postgres-rustls`. Swapping to rustls is a fork, not a flag, and would panic on
  `sslmode=require` (RDS/Cloud SQL/Supabase/Neon). **native-tls/OpenSSL is mandatory on Linux.**
- **Three C libraries, not one**: bundled SQLite, zlib (`mysql`'s `minimal` → `flate2/zlib` →
  `libz-sys`), and OpenSSL (Linux only).
- **OpenSSL is a Linux-only problem.** `native-tls` maps to SChannel on Windows and
  Security.framework on macOS, so 3 of 5 targets have zero OpenSSL.
- `tiberius` is pulled with `default-features = false`, so **MSSQL connections are unencrypted** with
  no Windows integrated auth. Upstream's choice; document it for consumers.

### Two upstream build settings live OUTSIDE the published crate

Both must be replicated explicitly or our binary differs functionally from `cargo install`:

| Upstream location | Setting | Replicate as |
| --- | --- | --- |
| `.cargo/config.toml` | `LIBSQLITE3_FLAGS = "-DSQLITE_ENABLE_MATH_FUNCTIONS"` | env var |
| workspace `Cargo.toml` | `[profile.release] lto = true, codegen-units = 1` | `CARGO_PROFILE_RELEASE_*` |

`libsqlite3-sys` *appends* `LIBSQLITE3_FLAGS` to its defaults, so omitting it silently ships a
SQLite without `floor()`/`pow()`.

## Build strategy (spike-verified)

Source is the **crates.io `.crate` tarball**, sha256-verified against the API, not a git clone:
immutable, content-addressed, bare-semver names, ships `Cargo.lock`, is patchable (unlike
`cargo install`), and carries the upstream commit in `.cargo_vcs_info.json`. Tag names never enter
the picture. **The `.crate` contains no LICENSE** — fetch it from
`raw.githubusercontent.com/rust-db/refinery/<sha1>/LICENSE` or you ship MIT binaries with no notice.

Linux needs vendored OpenSSL via a target-scoped one-table patch appended to the crate's
`Cargo.toml`:

```toml
[target.'cfg(target_os = "linux")'.dependencies]
openssl = { version = "0.10", features = ["vendored"] }
```

This **breaks `--locked`** on Linux (adds `openssl-src` to the graph). Don't paper over it — assert
the lock delta is *exactly* `openssl-src`. macOS/Windows build with plain `--locked`, no patch.

Two Linux traps:
- **Never set `PKG_CONFIG_ALLOW_CROSS=1`.** With `--target` ≠ host, pkg-config correctly refuses to
  probe, so `libz-sys` builds zlib from source. Enabling it links the host's **glibc** zlib into a
  static musl binary.
- **Never set bare `CC=musl-gcc`.** Use `CC_<target_with_underscores>` so host build scripts keep
  using the normal glibc `cc`.

### Spike results (x86_64-unknown-linux-musl, 2026-09-14)

Measured locally, so these are facts, not estimates:

- Pristine `Cargo.lock` is self-consistent; lock delta after the patch was **exactly `openssl-src`**.
- Built `openssl-src v300.6.1+3.6.3`, `libz-sys`, `libsqlite3-sys` from C source. Clean build.
- Result: **13 MB**, `static-pie`, stripped, **0 `NEEDED`, 0 `INTERP`**, `ldd` → "statically linked",
  `strings` → `OpenSSL 3.6.3`.
- Runs on `alpine:3.20` with no glibc. Applied 2 migrations, second run idempotent, `-e` with a
  `sqlite://` URL worked with no config file.
- **3m58s wall on 20 cores** (25m54s CPU). GitHub runners have 4 cores → expect ~15–25 min/target;
  `timeout-minutes: 75` is right.

`aarch64-unknown-linux-musl` is **still unverified** and remains the highest risk: it is the only
target where all three C libraries are cross-libc compiled. Local verification is impossible in this
dev environment (rootless Docker, no passwordless sudo, so host binfmt/QEMU cannot be registered) —
it must be proven on a real `ubuntu-24.04-arm` runner.

## Commands

Local toolchain: `cargo` 1.98, `cross`, `act`, `docker` (**rootless**), `gh`, `jq`, `musl-gcc`.
Not available: `node`/`npm` (hence a **composite** action, not JS), `shellcheck`, `yamllint`, `bats`,
`python3-yaml`, arm64 emulation, passwordless sudo.

```bash
# Unit-test the pure helpers
bash -n scripts/lib.sh && . scripts/lib.sh && normalize_version v0.9.2

# Reproduce the musl spike (~4 min on 20 cores)
curl -sSL https://static.crates.io/crates/refinery_cli/refinery_cli-0.9.2.crate | tar -xz
cd refinery_cli-0.9.2
printf '\n[target.%s.dependencies]\nopenssl = { version = "0.10", features = ["vendored"] }\n' \
  "'cfg(target_os = \"linux\")'" >> Cargo.toml
CC_x86_64_unknown_linux_musl=musl-gcc LIBSQLITE3_FLAGS=-DSQLITE_ENABLE_MATH_FUNCTIONS \
CARGO_PROFILE_RELEASE_LTO=true CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
  cargo build --release --target x86_64-unknown-linux-musl --bin refinery

# Prove it is static and musl-clean
BIN=target/x86_64-unknown-linux-musl/release/refinery
file "$BIN"; ! readelf -d "$BIN" | grep -q NEEDED; ! readelf -l "$BIN" | grep -q INTERP
docker run --rm --platform linux/amd64 -v "$PWD/$(dirname $BIN)":/x:ro alpine:3.20 /x/refinery --version

# Inspect upstream state (the premise of this project)
gh api repos/rust-db/refinery/releases --jq '.[] | {tag:.tag_name, assets:[.assets[].name]|length}'
curl -sS -H 'User-Agent: setup-refinery (dsantana)' \
  https://crates.io/api/v1/crates/refinery_cli | jq -r .crate.max_stable_version

# Workflows locally
act -l
act push -j install -s GITHUB_TOKEN="$(gh auth token)" --matrix os:ubuntu-latest
```

Always pass `--platform linux/amd64` to `docker run`: an arm64 pull earlier in a session poisons the
local image tag and later runs fail with `exec format error`.

## Conventions

- **Commit messages: never add `Co-Authored-By` trailers.** No agent/tool attribution of any kind.
- Pin every third-party action to a full commit SHA. Consumers inherit our supply chain. Prefer the
  preinstalled `gh` CLI in `run:` steps over third-party release actions — no pin needed, no
  supply-chain surface, and it works under `act` behind a `dry_run` input.
- Pin the upstream refinery version explicitly; bumping it must be a visible commit.
- Least-privilege `permissions:` per job; `contents: write` only where a release is created.
- Tag namespaces must never collide: action releases are `v1.2.3` + a moving `v1`; binary payloads
  are `refinery-v<X.Y.Z>` created with **`make_latest=false`**. Never a bare `v0.9.2` tag — it would
  read as an action version. Enforce both patterns with a guard job.
- Action inputs are a permanent API: adding an optional defaulted input is fine, adding a required
  one or removing any is breaking. Current surface is three inputs (`version`, `token`, `fallback`)
  and should stay small.
- Checksum verification fails closed. There is no override input, and there must never be one.
