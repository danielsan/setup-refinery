#!/usr/bin/env bash
# Package one built binary into dist/ with its licence, notices, provenance and
# checksum sidecar.
#
# Env in: VERSION, TARGET, EXT, EXE, EXTRA_EXT, OPENSSL_KIND, UPSTREAM_SHA1
set -euo pipefail

: "${VERSION:?}" "${TARGET:?}"
EXT="${EXT:-tar.gz}"
EXE="${EXE:-}"
EXTRA_EXT="${EXTRA_EXT:-}"
OPENSSL_KIND="${OPENSSL_KIND:-unknown}"

# targets.json records the TLS backend a target *normally* uses, but on Linux
# that is only true when the upstream version actually pulls native-tls.
# 0.9.0/0.9.1 map refinery_cli/postgresql to refinery-core/postgres, so no
# OpenSSL is linked and fetch-source.sh applies no patch. Correct the notices
# rather than let them claim an OpenSSL the binary does not contain.
if [ "${REFINERY_PG_TLS:-on}" = off ] && [ "$OPENSSL_KIND" = vendored-static ]; then
  OPENSSL_KIND=no-postgres-tls
fi
SRC="src-build/refinery_cli-$VERSION"
BIN="$SRC/target/$TARGET/release/refinery$EXE"

[ -f "$BIN" ] || { printf '::error title=package::missing binary %s\n' "$BIN" >&2; exit 1; }

rm -rf dist stage && mkdir -p dist stage

cp "$BIN" "stage/refinery$EXE"
cp "$SRC/LICENSE" stage/LICENSE
[ -f "$SRC/README.md" ] && cp "$SRC/README.md" stage/README.md

BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"

# ------------------------------------------------------- third-party notices
#
# A statically linked Rust binary embeds a few hundred MIT/Apache-2.0/BSD crates,
# and MIT requires the notice to accompany BINARY copies too. Obligations differ
# per target: vendored OpenSSL (Apache-2.0) is in the Linux archives only.
{
  printf '# Third-party notices\n\n'
  printf 'This archive contains a statically linked build of `refinery_cli` %s\n' "$VERSION"
  printf 'for `%s`. The binary embeds the Rust crates listed below, plus the C\n' "$TARGET"
  printf 'libraries noted at the end.\n\n'
  printf 'refinery itself is redistributed under the MIT option of its\n'
  printf '`MIT OR Apache-2.0` dual licence; see `LICENSE`.\n\n'
  printf '## C libraries\n\n'
  printf -- '- **SQLite** (bundled, compiled from source): public domain.\n'
  printf -- '- **zlib** (via `libz-sys`, compiled from source): zlib licence.\n'
  case "$OPENSSL_KIND" in
    vendored-static)
      printf -- '- **OpenSSL 3.x** (vendored via `openssl-src`, statically linked): Apache-2.0.\n' ;;
    security-framework)
      printf -- '- **No OpenSSL.** TLS uses the macOS Security.framework via `native-tls`.\n' ;;
    schannel)
      printf -- '- **No OpenSSL.** TLS uses Windows SChannel via `native-tls`.\n' ;;
    no-postgres-tls)
      printf -- '- **No OpenSSL.** This refinery version maps `postgresql` to\n'
      printf -- '  `refinery-core/postgres` rather than `postgres-tls`, so no TLS backend is\n'
      printf -- '  compiled in and `sslmode=require` will not work. Use 0.9.2 or later for\n'
      printf -- '  Postgres over TLS.\n' ;;
  esac
  printf '\n## Rust crates\n\n'
  printf '| crate | version | licence |\n|---|---|---|\n'
  # cargo metadata is always available; cargo-about would give full licence texts
  # but needs an extra install. This inventory is the minimum viable compliance
  # baseline -- see AGENTS.md.
  ( cd "$SRC" && cargo metadata --format-version 1 --all-features 2>/dev/null \
    | jq -r '.packages[] | "| \(.name) | \(.version) | \(.license // "see repository") |"' \
    | sort -u ) || printf '| (inventory unavailable) | | |\n'
} > stage/THIRD-PARTY-NOTICES.md

# ------------------------------------------------------- provenance

{
  printf 'setup-refinery build information\n'
  printf '================================\n\n'
  printf 'refinery_cli version : %s\n' "$VERSION"
  printf 'target triple        : %s\n' "$TARGET"
  printf 'binary sha256        : %s\n' "$BIN_SHA"
  printf 'upstream commit      : %s\n' "${UPSTREAM_SHA1:-unknown}"
  printf 'source               : https://static.crates.io/crates/refinery_cli/refinery_cli-%s.crate\n' "$VERSION"
  printf 'source sha256        : verified against the crates.io API at build time\n'
  printf '\n'
  printf 'rustc                : %s\n' "$(rustc -vV | tr '\n' ' ')"
  _locked="$(tr -d ' \n' < "$SRC/.locked_flag" 2>/dev/null || echo '--locked')"
  printf 'cargo command        : cargo build%s --release --target %s --bin refinery\n' \
    "${_locked:+ $_locked}" "$TARGET"
  printf '\n'
  printf 'features             : default (mysql, postgresql, sqlite-bundled, mssql)\n'
  printf 'int8-versions        : OFF  <-- i32 migration versions, standard schema history\n'
  printf 'TLS backend          : %s\n' "$OPENSSL_KIND"
  printf 'Postgres TLS         : %s\n' \
    "$([ "${REFINERY_PG_TLS:-on}" = on ] \
        && echo 'YES (refinery-core/postgres-tls -> native-tls)' \
        || echo 'NO  (refinery-core/postgres; upstream added postgres-tls in 0.9.2)')"
  printf 'MSSQL TLS            : none (tiberius is built with default-features = false)\n'
  printf '\n'
  printf 'LIBSQLITE3_FLAGS     : %s\n' "${LIBSQLITE3_FLAGS:-<unset>}"
  printf 'profile.release      : lto=%s codegen-units=%s strip=%s\n' \
    "${CARGO_PROFILE_RELEASE_LTO:-<unset>}" \
    "${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-<unset>}" \
    "${CARGO_PROFILE_RELEASE_STRIP:-<unset>}"
  printf '\n'
  printf 'Differences from a plain `cargo install refinery_cli`:\n'
  if [ -s "$SRC/PATCH.txt" ]; then
    printf '  1. Cargo.toml patched to vendor OpenSSL (Linux only):\n'
    sed 's/^/     /' "$SRC/PATCH.txt"
  else
    printf '  1. No source patch on this target.\n'
  fi
  printf '  2. LIBSQLITE3_FLAGS and [profile.release] replicated from upstream,\n'
  printf '     which live outside the published crate.\n'
  printf '  3. strip = "symbols" for a smaller asset.\n'
  printf '\n'
  printf 'built by             : %s/%s/actions/runs/%s\n' \
    "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY:-local}" "${GITHUB_RUN_ID:-local}"
  printf 'built at             : %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > stage/BUILDINFO.txt

cp stage/BUILDINFO.txt "dist/BUILDINFO-$TARGET.txt"

# ------------------------------------------------------- archives

NAME="refinery-$VERSION-$TARGET"

# Flat archives (no wrapper directory): simplest for the consuming action, which
# also tolerates the extra files via `find`.
tar -C stage -czf "dist/$NAME.tar.gz" .
printf 'packaged dist/%s.tar.gz\n' "$NAME"

# Windows also gets a .zip for humans clicking in a browser, but the action
# prefers the .tar.gz because Git Bash's tar cannot read zip and `unzip` is not
# reliably present.
if [ -n "$EXTRA_EXT" ]; then
  ( cd stage && \
    if command -v zip >/dev/null 2>&1; then zip -qr "../dist/$NAME.zip" .
    else powershell -NoProfile -NonInteractive -Command \
      "Compress-Archive -Path * -DestinationPath '../dist/$NAME.zip' -Force"; fi )
  printf 'packaged dist/%s.%s\n' "$NAME" "$EXTRA_EXT"
fi

# Per-asset sidecars: the action reads these (one tiny GET, no parsing of
# unrelated lines). finalize/ also builds an aggregate SHA256SUMS for humans.
( cd dist && for f in "$NAME".*; do
    case "$f" in *.sha256) continue ;; esac
    sha256sum "$f" > "$f.sha256"
    cat "$f.sha256"
  done )
