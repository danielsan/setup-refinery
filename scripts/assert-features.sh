#!/usr/bin/env bash
# Assert that the build has exactly the feature set we promise consumers.
#
# This is the safety net that makes unattended upstream tracking defensible: the
# day upstream changes its default features, or anyone adds --all-features, the
# pipeline must fail rather than silently ship a binary whose drivers or schema
# semantics differ from what the README claims.
#
# Env in: TARGET (target triple). Run from the crate root.
#
# NOTE: `cargo tree -e features` is the wrong tool here. It only renders the
# features named in a direct dependency declaration -- for refinery_cli that is
# just refinery-core's "toml" and "config" -- so the driver features enabled
# through refinery_cli's own [features] table are invisible to it. `cargo
# metadata`'s resolve graph reports the actually-resolved feature set per
# package, which is what we need.
set -euo pipefail

: "${TARGET:?TARGET is required}"

fail() { printf '::error title=feature-contract::%s\n' "$*" >&2; exit 1; }

META="$(cargo metadata --format-version 1 --filter-platform "$TARGET")" \
  || fail "cargo metadata failed for $TARGET"

features_of() { # features_of <package-name-pattern>
  printf '%s' "$META" | jq -r --arg p "$1" \
    '[.resolve.nodes[] | select(.id | test($p)) | .features[]] | unique | join(" ")'
}

CLI_FEATURES="$(features_of 'refinery_cli')"
CORE_FEATURES="$(features_of 'refinery-core')"

printf 'refinery_cli  : %s\n' "$CLI_FEATURES"
printf 'refinery-core : %s\n' "$CORE_FEATURES"

has() { # has <haystack> <needle>
  case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

# The four drivers we promise in the README.
for f in mysql postgresql sqlite-bundled mssql; do
  has "$CLI_FEATURES" "$f" || fail "refinery_cli lost the '$f' feature (have: $CLI_FEATURES)"
done

# Which refinery-core features those map to is NOT a constant across upstream
# versions, so deriving the expectation from a hardcoded list would be wrong.
# 0.9.0 and 0.9.1 map refinery_cli/postgresql -> refinery-core/postgres; 0.9.2
# re-wired it to refinery-core/postgres-tls. Read the mapping out of the crate's
# own [features] table and assert that whatever it points at is actually
# enabled -- that way the contract tracks upstream instead of drifting from it.
#
# Every enabled refinery_cli feature is expanded, which covers the intra-crate
# hops too (sqlite-bundled -> sqlite -> refinery-core/rusqlite) without needing
# a closure: the resolver already told us the full set of enabled cli features.
REQUIRED_CORE="$(printf '%s' "$META" | jq -r \
  --argjson enabled "$(printf '%s' "$CLI_FEATURES" | jq -R 'split(" ")')" '
    (.packages[] | select(.name == "refinery_cli") | .features) as $map
    | [$enabled[] | $map[.] // []]
    | flatten
    | map(select(startswith("refinery-core/")) | ltrimstr("refinery-core/"))
    | unique | join(" ")')" || fail "could not derive the refinery-core feature mapping"

printf 'required core : %s\n' "$REQUIRED_CORE"

[ -n "$REQUIRED_CORE" ] || fail "refinery_cli maps none of its features onto refinery-core"

for f in $REQUIRED_CORE; do
  has "$CORE_FEATURES" "$f" \
    || fail "refinery-core lost the '$f' feature that refinery_cli asks for (have: $CORE_FEATURES)"
done

# These two are load-bearing for the README's claims and have been stable across
# all of 0.9.x, so assert them by name as well as via the mapping above.
for f in rusqlite-bundled tiberius-config; do
  has "$CORE_FEATURES" "$f" || fail "refinery-core lost the '$f' feature (have: $CORE_FEATURES)"
done

# Postgres TLS is a real, consumer-visible capability difference between
# upstream versions, not a build flaw: postgres-tls pulls native-tls, which is
# what links OpenSSL on Linux. Record it rather than assume it, so the binary
# verification and the shipped notices describe the binary that was actually
# built. rustls is not a substitute -- the sync driver panics under it.
if has "$CORE_FEATURES" postgres-tls; then
  PG_TLS=on
else
  PG_TLS=off
  printf '::warning title=feature-contract::refinery %s has no Postgres TLS support: refinery_cli/postgresql maps to refinery-core/postgres, not postgres-tls (upstream added postgres-tls in 0.9.2). sslmode=require will not work with this binary.\n' \
    "${VERSION:-<unknown>}"
fi
printf 'postgres TLS  : %s\n' "$PG_TLS"
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'REFINERY_PG_TLS=%s\n' "$PG_TLS" >> "$GITHUB_ENV"
fi

# int8-versions would change SchemaVersion from i32 to i64 and with it the
# semantics of the refinery_schema_history table. It must never be enabled.
if has "$CLI_FEATURES" int8-versions || has "$CORE_FEATURES" int8-versions; then
  fail "int8-versions is enabled; it changes refinery_schema_history semantics"
fi

printf '::notice::feature contract OK for %s (four drivers present, int8-versions absent)\n' "$TARGET"
