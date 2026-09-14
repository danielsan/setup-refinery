#!/usr/bin/env bash
# Decide WHICH refinery version to build and WHICH targets still need an asset.
#
# Writes GitHub step outputs: version, tag, matrix, any, upstream_sha1.
# With --check-only, writes only `version` and `needed` (used by watch-upstream.yml,
# so the scheduled and dispatched paths cannot drift apart).
#
# Version discovery uses crates.io, never git tags: upstream's tag list contains
# unsortable entries (0.10, 0.4, 0.3, 0.2 mixed with v0.9.2) and cannot express
# yank status (0.8.15 is yanked).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGETS_JSON="$REPO_ROOT/.github/targets.json"

CHECK_ONLY=false
[ "${1-}" = --check-only ] && CHECK_ONLY=true

UA="setup-refinery (+https://github.com/${GITHUB_REPOSITORY:-danielsan/setup-refinery})"
out() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/stdout}"; }
fail() { printf '::error title=resolve-upstream::%s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ version

VERSION="${INPUT_VERSION-}"
VERSION="${VERSION//[$' \t\r\n']/}"
VERSION="${VERSION#v}"

if [ -z "$VERSION" ]; then
  # max_stable_version rather than .versions[0]: do not depend on array ordering.
  CRATES_JSON="$(curl -sSfL --max-time 30 -A "$UA" \
    https://crates.io/api/v1/crates/refinery_cli)" \
    || fail "could not query crates.io for refinery_cli"
  VERSION="$(printf '%s' "$CRATES_JSON" | jq -r '.crate.max_stable_version')"
  [ -n "$VERSION" ] && [ "$VERSION" != null ] \
    || fail "crates.io returned no max_stable_version for refinery_cli"
  # Belt and braces: max_stable_version should never be yanked, but assert it.
  yanked="$(printf '%s' "$CRATES_JSON" \
    | jq -r --arg v "$VERSION" '.versions[] | select(.num == $v) | .yanked')"
  [ "$yanked" = false ] || fail "crates.io reports refinery_cli $VERSION as yanked"
  printf 'resolved latest upstream version from crates.io: %s\n' "$VERSION"
else
  case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) : ;;
    *) fail "version must be an exact X.Y.Z (got '$VERSION')" ;;
  esac
  meta="$(curl -sSfL --max-time 30 -A "$UA" \
    "https://crates.io/api/v1/crates/refinery_cli/$VERSION")" \
    || fail "refinery_cli $VERSION does not exist on crates.io"
  [ "$(printf '%s' "$meta" | jq -r '.version.yanked')" = false ] \
    || fail "refinery_cli $VERSION is yanked on crates.io; refusing to build it"
fi

TAG="refinery-v$VERSION"
out version "$VERSION"
out tag "$TAG"

# ------------------------------------------------------------------ what exists

# `gh release view` fails when the release is absent, which is not an error here.
EXISTING=""
if command -v gh >/dev/null 2>&1; then
  EXISTING="$(gh release view "$TAG" --json assets --jq '.assets[].name' 2>/dev/null || true)"
fi

WANT="$(jq -r --arg v "$VERSION" \
  '.targets[] | "refinery-\($v)-\(.target).\(.ext)"' "$TARGETS_JSON")"

FORCE="${INPUT_FORCE:-false}"
MISSING=""
while IFS= read -r asset; do
  [ -n "$asset" ] || continue
  if [ "$FORCE" = true ]; then
    MISSING="$MISSING$asset"$'\n'
  elif ! printf '%s\n' "$EXISTING" | grep -qxF "$asset"; then
    MISSING="$MISSING$asset"$'\n'
  fi
done <<<"$WANT"

# Map the missing asset names back to full matrix entries.
MATRIX="$(jq -c --arg v "$VERSION" --arg missing "$MISSING" '
  ($missing | split("\n") | map(select(length > 0))) as $m
  | [ .targets[]
      | select(("refinery-\($v)-\(.target).\(.ext)") | IN($m[]))
    ]' "$TARGETS_JSON")"

COUNT="$(printf '%s' "$MATRIX" | jq 'length')"
out matrix "$MATRIX"
if [ "$COUNT" -gt 0 ]; then out any true; else out any false; fi

# watch-upstream also treats a still-draft release as "needed", so an interrupted
# run gets picked up on the next tick rather than silently staying unpublished.
DRAFT=false
if command -v gh >/dev/null 2>&1; then
  DRAFT="$(gh release view "$TAG" --json isDraft --jq '.isDraft' 2>/dev/null || echo false)"
fi
if [ "$COUNT" -gt 0 ] || [ "$DRAFT" = true ]; then
  out needed true
else
  out needed false
fi

printf 'version=%s tag=%s targets_needed=%s draft=%s\n' "$VERSION" "$TAG" "$COUNT" "$DRAFT"
printf '%s\n' "$MATRIX" | jq -r '.[] | "  needs build: \(.target) on \(.runner)"'

$CHECK_ONLY && exit 0

# ------------------------------------------------------------------ upstream sha

# .cargo_vcs_info.json records the exact upstream commit, so the LICENSE can be
# fetched from that commit and no tag-name guessing is ever required.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if curl -sSfL --max-time 60 \
     "https://static.crates.io/crates/refinery_cli/refinery_cli-$VERSION.crate" \
     | tar -xzO "refinery_cli-$VERSION/.cargo_vcs_info.json" > "$TMP/vcs.json" 2>/dev/null \
   && [ -s "$TMP/vcs.json" ]; then
  SHA1="$(jq -r '.git.sha1 // empty' "$TMP/vcs.json")"
else
  SHA1=""
fi
if [ -z "$SHA1" ]; then
  # Degenerate fallback for older crates without vcs info: probe both tag spellings.
  for r in "$VERSION" "v$VERSION"; do
    if git ls-remote --exit-code --tags https://github.com/rust-db/refinery \
         "refs/tags/$r" >/dev/null 2>&1; then SHA1="$r"; break; fi
  done
  [ -n "$SHA1" ] || SHA1=main
  printf '::warning::no .cargo_vcs_info.json for %s; falling back to git ref %s\n' "$VERSION" "$SHA1"
fi
out upstream_sha1 "$SHA1"
printf 'upstream ref: %s\n' "$SHA1"
