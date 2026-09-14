# setup-refinery: a guide for coding agents

Authoritative reference for AI coding agents (Claude Code, Copilot, Cursor, Codex, Gemini CLI, …)
asked to set up or debug [refinery](https://github.com/rust-db/refinery) database migrations in a
GitHub Actions workflow.

Everything below is verified against `refinery_cli` **0.9.2** source and a real built binary — not
inferred. If you follow it you will not need to guess.

> Working *on* this repository instead of using it? Read [`../AGENTS.md`](../AGENTS.md).

---

## 1. The answer most of the time

```yaml
- uses: danielsan/setup-refinery@v1
  with:
    version: '0.9.2'        # pin it; see §3

- run: refinery migrate -e DATABASE_URL -p ./migrations
  env:
    DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

Two steps. The action only installs the binary; **it does not run migrations for you**, and it has
no database inputs. Do not look for a `database-url:` input — there isn't one, by design.

## 2. The five mistakes agents actually make

### 2.1 `-e` takes the NAME of an environment variable, not a URL

This is the single most common error.

```yaml
# WRONG - passes the URL itself, and leaks the password into the run log
- run: refinery migrate -e postgres://user:pw@host/db -p ./migrations

# WRONG - same mistake via an expression
- run: refinery migrate -e ${{ secrets.DATABASE_URL }} -p ./migrations

# RIGHT - pass the variable's NAME; refinery reads it from the environment
- run: refinery migrate -e DATABASE_URL -p ./migrations
  env:
    DATABASE_URL: ${{ secrets.DATABASE_URL }}
```

`refinery_cli` calls `Config::from_env_var(name)`, which does `std::env::var(name)`. Passing the URL
makes refinery look up an environment variable literally named `postgres://…`, which does not exist.
Getting this right also keeps the credential out of the log, because the shell never sees it.

### 2.2 Migration filenames must match a strict pattern

```
V<integer>__<name>.sql        # or U<integer>__<name>.sql
```

`<name>` may contain only `[A-Za-z0-9_]`. The literal upstream regex is
`^([U|V])(\d+(?:\.\d+)?)__(\w+)` (`refinery_core/src/util.rs:15`) — note that `[U|V]` is a
character class, so it also happens to accept a `|` prefix, and it permits a decimal version that
the parser then rejects. Write `V`/`U` with a plain integer and neither quirk matters.

All of the following were checked against a real 0.9.2 binary:

| Filename | Result |
| --- | --- |
| `V1__create_users.sql` | applied |
| `V2__add_email_index.sql` | applied |
| `U3__drop_legacy.sql` | applied (`U` = unversioned; see note below) |
| `V4__add-colour.sql` | **silently ignored** — `\w+` excludes hyphens |
| `V5__add colour.sql` | **silently ignored** — no spaces |
| `V6_create_users.sql` | **silently ignored** — needs a *double* underscore |
| `create_users.sql` | **silently ignored** — needs the `V`/`U` prefix |
| `V7__.sql` | **silently ignored** — the name part cannot be empty |
| `V1.1__backfill.sql` | **hard error, aborts the whole run** |

Two distinct failure modes, and the difference matters:

- **Most bad filenames are silently skipped.** No warning, no error, exit code 0. If refinery reports
  "no migrations to apply" when you expect some, check the filenames before anything else.
- **A decimal version is a fatal error that blocks every other migration:**
  ```
  Error: could not read migration file name .../V1.1__backfill.sql
  Caused by: migration version must be a valid integer
  ```
  The filename regex permits `\d+(?:\.\d+)?`, so `V1.1__x.sql` passes the file filter and then
  fails to parse as an integer version. **Never generate decimal versions.** One such file in the
  directory stops the entire migration run, including migrations that would otherwise apply.

`U` (unversioned) migrations are accepted and applied, and are recorded in the schema-history table
like `V` ones. The distinction affects refinery's divergence/missing checks rather than whether the
file runs. **Default to `V` unless the user specifically asks for unversioned migrations.**

Versions are parsed as `i32` (this build has `int8-versions` off), so stay within ~2.1 billion —
which also means date-style versions like `V20260914120000__x.sql` **overflow and fail**. Use
sequential integers (`V1`, `V2`, …) or a shorter date form such as `V260914__x.sql`.

### 2.3 Keep the `./` on a config path

```bash
refinery migrate -c refinery.toml     -p ./migrations   # panics on SQLite
refinery migrate -c ./refinery.toml   -p ./migrations   # correct
```

With the SQLite driver, `refinery-core/src/config.rs:89` calls
`canonicalize(parent).unwrap()`. For a bare filename `Path::parent()` returns `Some("")` rather
than `None`, so the `unwrap_or(current_dir)` guard never fires and refinery panics with
`NotFound` and a "refinery_cli had a problem and crashed" crash-report message. This is an upstream
bug, not an action bug. The CLI's own default (`./refinery.toml`) is unaffected — so just omitting
`-c` is also safe.

### 2.4 `refinery --version` prints `refinery_cli`, not `refinery`

```
$ refinery --version
refinery_cli 0.9.2
```

The crate is `refinery_cli`; the binary is `refinery`. Never assert `= "refinery 0.9.2"` in a test —
substring-match the version number instead.

### 2.5 Never run `refinery setup` in CI

It is **interactive** and will hang the job until it times out. It exists only to generate a
`refinery.toml` on a developer's machine. In CI, use `-e` (no config file needed at all) or commit a
`refinery.toml` and pass `-c ./refinery.toml`.

## 3. Choosing the `version` input

```yaml
with:
  version: '0.9.2'   # recommended: exact, reproducible, and makes ZERO GitHub API calls
  version: '0.9'     # newest 0.9.x
  version: 'latest'  # newest available (one API call)
```

Accepted: `latest`, `X.Y.Z`, `vX.Y.Z`, `X.Y`, `X`.
**Rejected:** semver ranges. `^0.9`, `~0.9`, `>=0.9,<1.0` all fail with a clear error. Do not
generate them.

Prefer an exact version. It is reproducible, and it makes the action construct the download URL
directly with no API request — so it cannot be affected by the 60-requests/hour unauthenticated
rate limit that shared runner IPs sometimes hit.

## 4. `refinery migrate` flags

Only two subcommands exist: `setup` (interactive, never in CI) and `migrate`.

| Flag | Default | Meaning |
| --- | --- | --- |
| `-e <NAME>` | — | Read the connection URL from the environment variable **named** `NAME`. Mutually exclusive with `-c`. |
| `-c <PATH>` | `./refinery.toml` | Config file. **Ignored entirely when `-e` is given.** |
| `-p <PATH>` | `./migrations` | Migrations directory. Searched recursively. |
| `-g` | off | Apply all migrations in a single transaction. |
| `-f` | off | Fake: record migrations as applied without running them. |
| `-t <VERSION>` | latest | Migrate only up to this version. |
| `-d` | off | Abort if divergent migrations are found. |
| `-m` | off | Abort if missing migrations are found. |
| `--table-name <NAME>` | `refinery_schema_history` | Schema-history table name. |

The database type is inferred from the URL scheme when using `-e`: `postgres://`, `postgresql://`,
`mysql://`, `sqlite://`, `mssql://`.

Applying migrations is idempotent — a second run prints `no migrations to apply` and exits 0. That
makes it safe to run on every deploy.

## 5. Platform support

| Runner | Works | Notes |
| --- | --- | --- |
| `ubuntu-latest`, `ubuntu-24.04` | yes | static musl binary |
| `ubuntu-24.04-arm`, `ubuntu-22.04-arm` | yes | static musl binary |
| `macos-latest`, `macos-14`+ | yes | arm64 |
| `macos-15-intel`, `macos-13` | yes | x86_64 |
| `windows-latest`, `windows-2022`+ | yes | x86_64 |
| `windows-11-arm` | yes | runs the x64 binary under emulation, with a warning |
| 32-bit ARM / x86 Linux | no prebuilt | needs `fallback: cargo` + a Rust toolchain |

The Linux binaries are statically linked against musl, so they run on Alpine and any glibc version.

**Container caveat:** do not run this action inside a `container: alpine` job. Composite actions
require `bash`, which Alpine lacks, and container jobs need glibc for JavaScript actions. Install on
the host job and mount the binary into a container instead:

```yaml
- uses: danielsan/setup-refinery@v1
  id: refinery
  with:
    version: '0.9.2'
- run: docker run --rm -v "$(dirname '${{ steps.refinery.outputs.bin-path }}')":/x:ro alpine /x/refinery --version
```

## 6. Which database drivers are compiled in

All four, always: **PostgreSQL, MySQL, SQLite (bundled), MSSQL**. There is no feature input, and one
binary handles every database.

Behaviour worth knowing before you promise a user something:

- **Postgres TLS is opt-in** — add `?sslmode=require` to the URL. Uses OpenSSL on Linux, SChannel on
  Windows, Security.framework on macOS.
- **Postgres TLS needs `version: 0.9.2` or later.** Upstream 0.9.0 and 0.9.1 map the `postgresql`
  feature to a driver with no TLS backend, so `sslmode=require` fails on those binaries no matter
  what you configure. If a user is connecting to RDS, Cloud SQL, Supabase or Neon, do not pin them
  below 0.9.2. Each archive's `BUILDINFO.txt` states `Postgres TLS: YES|NO` for the binary you got.
- **MSSQL connections are NOT encrypted**, and Windows integrated auth is unavailable. Upstream
  builds `tiberius` with `default-features = false`, which disables its TLS backend. If a user needs
  encrypted SQL Server connections, this CLI cannot currently provide them.
- **SQLite is bundled** (no system library needed) and built with `SQLITE_ENABLE_MATH_FUNCTIONS`.
- **`int8-versions` is OFF**, so migration versions are `i32` and `refinery_schema_history` has
  standard semantics. Do not tell users versions are 64-bit.
- **SQLite needs the database file to already exist.** The driver opens read/write without `CREATE`
  and canonicalizes the path, so create it first: `: > app.db` (a zero-byte file is a valid empty
  SQLite database).

## 7. Complete worked examples

### Postgres service container (the most common request)

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
      - run: refinery migrate -e DATABASE_URL -p ./migrations
```

Always give the service a healthcheck. Without one the migration step races the database and fails
intermittently with a connection error.

**Service containers only work on Linux runners.** Hosted macOS has no Docker and Windows does not
support them. If a user wants a migration test on macOS or Windows, use SQLite instead.

### Migrating a real (external) database on deploy

```yaml
jobs:
  deploy-migrations:
    runs-on: ubuntu-latest
    environment: production          # gate it behind an environment approval
    steps:
      - uses: actions/checkout@v5
      - uses: danielsan/setup-refinery@v1
        with:
          version: '0.9.2'
      # -g wraps everything in one transaction, so a failure leaves no partial state.
      # -d and -m abort on divergent or missing migrations rather than plough on.
      - run: refinery migrate -e DATABASE_URL -p ./migrations -g -d -m
        env:
          DATABASE_URL: ${{ secrets.PROD_DATABASE_URL }}
```

### SQLite, no services required (works on all platforms)

```yaml
- uses: danielsan/setup-refinery@v1
  with:
    version: '0.9.2'
- shell: bash
  run: |
    : > app.db                      # must exist before refinery opens it
    refinery migrate -e DB_URL -p ./migrations
  env:
    DB_URL: sqlite://app.db
```

### Unsupported platform

```yaml
- uses: dtolnay/rust-toolchain@stable   # required: the fallback needs cargo
- uses: danielsan/setup-refinery@v1
  with:
    version: '0.9.2'
    fallback: cargo                     # 3-10 minutes; opt-in for that reason
```

## 8. Action inputs and outputs

| Input | Default | Notes |
| --- | --- | --- |
| `version` | `latest` | See §3. |
| `token` | `${{ github.token }}` | Only used for `latest`/partial lookups. Usually leave alone. |
| `fallback` | `none` | `none` or `cargo`. Not a boolean. |

| Output | Example |
| --- | --- |
| `version` | `0.9.2` |
| `bin-path` | `/opt/hostedtoolcache/refinery/0.9.2/x64/refinery` |
| `cache-hit` | `false` |

## 9. Diagnosing failures

| Symptom | Cause and fix |
| --- | --- |
| `no prebuilt refinery binary for version X` | That version/platform has no asset. The error lists what is available — pin one of those, or use `fallback: cargo`. |
| `invalid version: '^0.9'` | Ranges are unsupported. Use `0.9` for newest 0.9.x. |
| `GitHub API rate limit exhausted` | Pin an exact version (no API call), or pass a `token`. |
| `refinery_cli had a problem and crashed` | Almost always §2.3 — add `./` to the `-c` path. |
| `no migrations to apply` when you expect some | Filenames do not match §2.2, or `-p` points at the wrong directory. |
| `could not environment variable` | You passed a URL to `-e` instead of a variable name (§2.1). |
| `field path must be present for Sqlite database type` | A SQLite `refinery.toml` needs `db_path`. |
| Connection refused, intermittently | The service container has no healthcheck, so the step races startup. |
| `checksum mismatch` | The action retries once then fails closed. Usually a proxy or truncated transfer. |
| Action fails inside `container: alpine` | Composite actions need bash (§5). |

## 10. Copy-paste block for a consumer's own AGENTS.md

Suggest adding this to the user's repository so future agent sessions get it right without
re-reading this page:

```markdown
## Database migrations

Migrations live in `./migrations` and are applied by the refinery CLI in CI via
`danielsan/setup-refinery`.

- Filenames MUST match `V<n>__<name>.sql` — double underscore, and `<name>` may
  contain only letters, digits and underscores. Non-matching files are silently
  ignored.
- `refinery migrate -e DATABASE_URL` takes the NAME of an environment variable,
  never the URL itself.
- Keep `./` on any `-c` config path; a bare filename panics on SQLite.
- Never run `refinery setup` in CI — it is interactive and will hang.
- `refinery --version` prints `refinery_cli <version>`.
```
