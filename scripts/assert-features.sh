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

# The refinery-core features those map to. postgres-tls is the important one:
# it is what makes Postgres TLS work at all, and rustls is not a substitute
# because the sync driver panics under it.
for f in postgres-tls rusqlite-bundled tiberius-config; do
  has "$CORE_FEATURES" "$f" || fail "refinery-core lost the '$f' feature (have: $CORE_FEATURES)"
done

# int8-versions would change SchemaVersion from i32 to i64 and with it the
# semantics of the refinery_schema_history table. It must never be enabled.
if has "$CLI_FEATURES" int8-versions || has "$CORE_FEATURES" int8-versions; then
  fail "int8-versions is enabled; it changes refinery_schema_history semantics"
fi

printf '::notice::feature contract OK for %s (four drivers present, int8-versions absent)\n' "$TARGET"
