#!/usr/bin/env bash
# Verify one freshly built refinery binary: it runs, it links only what we expect,
# and it can actually apply a migration.
#
# Env in: BIN (path to the binary), VERSION, TARGET, RUNNER_OS
set -euo pipefail

: "${BIN:?BIN is required}"
: "${VERSION:?VERSION is required}"
: "${TARGET:?TARGET is required}"
OS="${RUNNER_OS:-$(uname -s)}"

fail() { printf '::error title=verify-binary::%s\n' "$*" >&2; exit 1; }

# Resolve to an absolute path once, so the migration test can cd into a temp dir
# without any relative-path juggling.
[ -f "$BIN" ] || fail "no such binary: $BIN"
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

# ------------------------------------------------------- it runs

# NOTE: refinery_cli prints "refinery_cli <version>", NOT "refinery <version>".
# Verified on a built binary -- do not assert equality against "refinery $VERSION".
actual="$("$BIN" --version | tr -d '\r')"
[ "$actual" = "refinery_cli $VERSION" ] \
  || fail "version mismatch: expected 'refinery_cli $VERSION', got '$actual'"
"$BIN" migrate --help >/dev/null || fail "'migrate --help' failed"
# Never invoke bare `refinery setup`: it is interactive and would hang CI.
printf 'runs: %s\n' "$actual"

# ------------------------------------------------------- linkage

case "$OS:$TARGET" in
  *:*-linux-musl)
    # Capture each tool's output to a variable before matching. Piping into
    # `grep -q` under `set -o pipefail` is a trap: grep exits at the first match,
    # the producer dies of SIGPIPE (141), and pipefail turns that success into a
    # pipeline failure.
    file_out="$(file "$BIN")"
    case "$file_out" in
      *"statically linked"*|*"static-pie"*) : ;;
      *) fail "$TARGET is not statically linked: $file_out" ;;
    esac

    # readelf rather than ldd: ldd exits non-zero on a static binary, which makes
    # shell logic fragile.
    dyn="$(readelf -d "$BIN" 2>/dev/null || true)"
    case "$dyn" in
      *NEEDED*) printf '%s\n' "$dyn" >&2
                fail "static binary has dynamic dependencies" ;;
    esac
    seg="$(readelf -l "$BIN" 2>/dev/null || true)"
    case "$seg" in
      *INTERP*) fail "static binary has a program interpreter" ;;
    esac

    # OpenSSL cannot be handshake-tested cheaply: sslmode=require against a
    # self-signed cert fails CA and hostname verification by design. So prove it
    # is LINKED. Honest limitation -- presence is structural, not functional.
    ssl="$(strings -a "$BIN" | grep -oE 'OpenSSL 3\.[0-9]+\.[0-9]+' | sort -u | head -1 || true)"
    [ -n "$ssl" ] || fail "no vendored OpenSSL found in the $TARGET binary"
    printf 'linkage: static, no NEEDED, no INTERP, %s\n' "$ssl"
    ;;
  macOS:*)
    otool_out="$(otool -L "$BIN")"
    # The real macOS hazard is Homebrew's openssl@3 / sqlite being linked instead
    # of the system frameworks.
    brewed="$(printf '%s\n' "$otool_out" | grep -E '/opt/homebrew|/usr/local' || true)"
    if [ -n "$brewed" ]; then
      printf '%s\n' "$brewed" >&2
      fail "binary links a non-system library (Homebrew leaked into the build)"
    fi
    printf 'linkage: system-only\n%s\n' "$otool_out"
    ;;
  Windows:*)
    printf 'linkage: checked by the PowerShell step in the workflow\n'
    ;;
esac

# ------------------------------------------------------- real migration

# SQLite needs no server, so this identical test runs on all five targets and
# exercises the riskiest component (the bundled SQLite C code) plus the TOML
# parser and the schema-history path.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/migrations"
printf 'CREATE TABLE smoke (id INTEGER PRIMARY KEY, v TEXT NOT NULL);\n' \
  > "$WORK/migrations/V1__smoke.sql"
printf 'CREATE TABLE second (id INTEGER PRIMARY KEY);\n' \
  > "$WORK/migrations/V2__second.sql"

# A 0-byte file is a valid empty SQLite database, and it MUST pre-exist: the
# driver opens READ_WRITE without CREATE, and config.rs canonicalizes db_path.
: > "$WORK/refinery.db"
# The config path MUST keep its "./" prefix. refinery-core config.rs:89 does
# canonicalize(parent).unwrap(), and for a bare filename parent() is Some("")
# rather than None, so the guard never fires and it panics.
printf '[main]\ndb_type = "Sqlite"\ndb_path = "refinery.db"\n' > "$WORK/refinery.toml"

cd "$WORK"
"$BIN" migrate -c ./refinery.toml -p migrations || fail "first migrate failed"

out="$("$BIN" migrate -c ./refinery.toml -p migrations)"
case "$out" in
  *"no migrations to apply"*) : ;;
  *) fail "second migrate was not idempotent, output was: $out" ;;
esac

# Also prove the -e path, which needs no config file at all: migrate.rs only
# reads -c when -e is absent, and db_type comes from the URL scheme.
: > url.db
DB_URL="sqlite://url.db" "$BIN" migrate -e DB_URL -p migrations \
  || fail "migrate -e with a sqlite:// URL failed"

printf 'migration round-trip: 2 applied, second run idempotent, -e path works\n'
printf '::notice::%s verified: runs, links correctly, applies migrations\n' "$TARGET"
