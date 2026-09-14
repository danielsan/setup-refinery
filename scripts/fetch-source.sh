#!/usr/bin/env bash
# Fetch, verify and (on Linux) patch the refinery_cli source for one build.
#
# Env in:  VERSION, TARGET, UPSTREAM_SHA1, SRC_DIR (default: ./src-build)
# Env out: writes $SRC_DIR/<crate>, plus LICENSE and PATCH.txt beside it.
#
# Source is the crates.io .crate tarball, not a git clone: immutable,
# content-addressed, always bare semver, ships Cargo.lock, and patchable.
set -euo pipefail

: "${VERSION:?VERSION is required}"
: "${TARGET:?TARGET is required}"
UPSTREAM_SHA1="${UPSTREAM_SHA1:-}"
SRC_DIR="${SRC_DIR:-src-build}"
UA="setup-refinery (+https://github.com/${GITHUB_REPOSITORY:-danielsan/setup-refinery})"

fail() { printf '::error title=fetch-source::%s\n' "$*" >&2; exit 1; }

mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

# ------------------------------------------------------- download + verify

CRATE="refinery_cli-$VERSION.crate"
EXPECTED="$(curl -sSfL --max-time 30 -A "$UA" \
  "https://crates.io/api/v1/crates/refinery_cli/$VERSION" | jq -r '.version.checksum')"
[ ${#EXPECTED} -eq 64 ] || fail "crates.io did not return a sha256 for refinery_cli $VERSION"

curl -sSfL --max-time 300 -o "$CRATE" \
  "https://static.crates.io/crates/refinery_cli/refinery_cli-$VERSION.crate" \
  || fail "could not download $CRATE"

ACTUAL="$(sha256sum "$CRATE" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] \
  || fail "source checksum mismatch for $CRATE: expected $EXPECTED, got $ACTUAL"
printf 'source sha256 verified: %s\n' "$ACTUAL"

rm -rf "refinery_cli-$VERSION"
tar -xzf "$CRATE"
cd "refinery_cli-$VERSION"

# ------------------------------------------------------- licence (NOT in the crate)

# The published .crate contains no LICENSE file, so it must come from the exact
# upstream commit recorded in .cargo_vcs_info.json. Skipping this would mean
# shipping MIT-licensed binaries with no licence notice.
REF="${UPSTREAM_SHA1:-$(jq -r '.git.sha1 // "main"' .cargo_vcs_info.json 2>/dev/null || echo main)}"
curl -sSfL --max-time 60 -o LICENSE \
  "https://raw.githubusercontent.com/rust-db/refinery/$REF/LICENSE" \
  || fail "could not fetch upstream LICENSE at ref $REF"
[ -s LICENSE ] || fail "fetched LICENSE is empty"
printf 'fetched upstream LICENSE from %s (%s bytes)\n' "$REF" "$(wc -c < LICENSE | tr -d ' ')"

# ------------------------------------------------------- lock sanity

cargo metadata --locked --format-version 1 >/dev/null \
  || fail "the shipped Cargo.lock is not self-consistent"
cp Cargo.lock Cargo.lock.pristine
printf 'pristine Cargo.lock is self-consistent\n'

# ------------------------------------------------------- Linux-only patch

: > PATCH.txt
LOCKED_FLAG="--locked"

# Does this upstream version actually use native-tls? refinery_cli/postgresql
# maps to refinery-core/postgres-tls in 0.9.2+, but to refinery-core/postgres in
# 0.9.0 and 0.9.1 -- and only postgres-tls pulls native-tls. Vendoring OpenSSL
# for a version that never references it would add a dependency the linker then
# discards, leaving a binary with no OpenSSL but archives claiming otherwise. So
# read the mapping out of the crate and let it decide whether to patch at all.
PG_TLS=off
if sed -n '/^\[features\]/,/^\[/p' Cargo.toml | grep -q 'refinery-core/postgres-tls'; then
  PG_TLS=on
fi
printf 'postgres TLS in refinery_cli %s: %s\n' "$VERSION" "$PG_TLS"

case "$TARGET:$PG_TLS" in
  *-linux-*:on)
    # refinery-core declares native-tls without a `vendored` feature, and a
    # transitive dependency's feature cannot be enabled from the command line.
    # Scoping to cfg(target_os="linux") guarantees this cannot perturb the
    # macOS/Windows graphs. macOS uses Security.framework, Windows SChannel.
    # Written once to PATCH.txt and then appended, so the recorded patch and the
    # applied patch cannot disagree (reading it back with `tail -n` would).
    cat > PATCH.txt <<'PATCH'

# ADDED BY setup-refinery CI: forces openssl-sys to build a static OpenSSL from
# source so the musl binary has no dynamic OpenSSL dependency. Linux-only.
# No behavioural change to refinery itself.
[target.'cfg(target_os = "linux")'.dependencies]
openssl = { version = "0.10", features = ["vendored"] }
PATCH
    cat PATCH.txt >> Cargo.toml

    # Adding a dependency changes the edge list, so --locked would now fail.
    # Re-resolve minimally, then ASSERT the only new package is openssl-src.
    cargo fetch >/dev/null
    ADDED="$(comm -13 <(grep '^name = ' Cargo.lock.pristine | sort -u) \
                      <(grep '^name = ' Cargo.lock          | sort -u))"
    if [ "$ADDED" != 'name = "openssl-src"' ]; then
      printf '::error title=fetch-source::unexpected Cargo.lock delta after the vendored-openssl patch%s\n' ""
      printf '%s\n' "$ADDED" >&2
      exit 1
    fi
    printf 'lock delta is exactly openssl-src, as expected\n'
    diff -u Cargo.lock.pristine Cargo.lock > LOCK_DELTA.txt || true
    LOCKED_FLAG=""
    ;;
  *-linux-*:off)
    # No native-tls in the graph, so there is nothing to vendor: keep the
    # pristine lock, keep --locked, and ship notices that say "no OpenSSL".
    printf '::warning title=fetch-source::refinery %s has no Postgres TLS support (refinery_cli/postgresql maps to refinery-core/postgres, not postgres-tls). Skipping the vendored-OpenSSL patch; this binary links no OpenSSL and sslmode=require will not work.\n' "$VERSION"
    ;;
esac

# Consumed by the build step.
printf '%s\n' "$LOCKED_FLAG" > .locked_flag
printf '%s\n' "$PG_TLS" > .pg_tls
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'REFINERY_PG_TLS=%s\n' "$PG_TLS" >> "$GITHUB_ENV"
fi
printf 'source ready: %s (locked_flag=%s)\n' "$PWD" "${LOCKED_FLAG:-<none>}"
