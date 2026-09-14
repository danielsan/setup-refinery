#!/usr/bin/env bash
# setup-refinery: resolve a refinery version, install the matching prebuilt binary
# and put it on PATH.
#
# Invoked from action.yml as `bash "$GITHUB_ACTION_PATH/scripts/setup.sh"`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# ------------------------------------------------------------------ inputs
#
# Validated by hand because the runner does NOT enforce `required: true`
# (actions/runner#1070), and composite actions do not expose inputs as INPUT_*
# automatically (actions/runner#665) -- action.yml maps them into env for us.

RAW_VERSION="${INPUT_VERSION-}"
TOKEN="${INPUT_TOKEN-}"
FALLBACK="${INPUT_FALLBACK:-none}"

case "$FALLBACK" in
  none|cargo) : ;;
  *) die "invalid fallback: '$FALLBACK' (expected 'none' or 'cargo')" ;;
esac

VERSION="$(normalize_version "$RAW_VERSION")" || die "$(printf 'invalid version: %s\n%s' \
  "'${RAW_VERSION}'" \
  "Expected 'latest', an exact version ('0.9.2' or 'v0.9.2'), or a partial version ('0.9').
Semver ranges such as '^0.9' or '>=0.9,<1.0' are not supported.")"

# Where the release assets live. Overridable for forks and GHES mirrors; not a
# documented-stable input.
RELEASE_REPO="${SETUP_REFINERY_RELEASE_REPO:-${ACTION_REPOSITORY:-${GITHUB_REPOSITORY-}}}"
[ -n "$RELEASE_REPO" ] || die "cannot determine the repository hosting refinery release assets"

API="${GITHUB_API_URL:-https://api.github.com}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
[ -n "${SETUP_REFINERY_DEBUG-}" ] && set -x

# ------------------------------------------------------------------ platform

OS="$(detect_os)"; ARCH="$(detect_arch)"
PLATFORM_SUPPORTED=true
TARGET=""; EXT="tar.gz"; EXE=""; NOTE=""
if _m="$(map_target "$OS" "$ARCH")"; then
  read -r TARGET EXT EXE NOTE <<<"$_m"
else
  # No prebuilt target for this OS/arch. Handled in main(), once cargo_fallback
  # is defined -- not here, because functions are only defined once their
  # definition has been executed.
  PLATFORM_SUPPORTED=false
fi

if $PLATFORM_SUPPORTED; then
  [ "$NOTE" = emulated ] && warn \
    "No native windows-arm64 build of refinery exists; installing the x86_64 binary, which runs under Windows' x64 emulation."
  info "runner: $OS/$ARCH -> target $TARGET"
else
  info "runner: $OS/$ARCH -> no prebuilt target"
fi

# ------------------------------------------------------------------ http

HDR_FILE="$(mktemp)"; BODY_FILE="$(mktemp)"
trap 'rm -f "$HDR_FILE" "$BODY_FILE"' EXIT

# api_get <url> -- GET the GitHub API into $BODY_FILE. Retries transient classes
# only. Never sleeps on a rate limit: the reset can be ~an hour away and burning
# billed CI minutes is worse than failing with two concrete fixes.
api_get() {
  local url="$1" code
  local -a args=(
    -sS -o "$BODY_FILE" -D "$HDR_FILE" -w '%{http_code}'
    --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors --retry-delay 2 --max-time 30
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28'
  )
  [ -n "$TOKEN" ] && args+=(-H "Authorization: Bearer $TOKEN")
  code="$(curl "${args[@]}" "$url" || true)"

  # A token can be absent-but-set, expired, or scoped with `permissions: {}`.
  # The data is public, so just retry anonymously rather than guessing why.
  if [ -n "$TOKEN" ] && { [ "$code" = 401 ] || [ "$code" = 403 ]; }; then
    warn "the supplied token was rejected (HTTP $code); retrying unauthenticated"
    TOKEN=""
    api_get "$url"; return
  fi

  if [ "$code" = 403 ] || [ "$code" = 429 ]; then
    if grep -qi '^x-ratelimit-remaining: *0' "$HDR_FILE"; then
      local reset now mins
      reset="$(awk -F': *' 'tolower($1)=="x-ratelimit-reset"{print $2+0}' "$HDR_FILE")"
      now="$(date +%s)"; mins=$(( (reset - now + 59) / 60 ))
      die "$(printf '%s\n%s' \
        "GitHub API rate limit exhausted (resets in ~${mins} min)." \
        "Fixes:
  1. pass a token:  with: { token: \${{ github.token }} }   # 1000 req/hr/repo
  2. pin an exact version:  with: { version: '0.9.2' }      # skips the API entirely")"
    fi
  fi
  [ "$code" = 200 ] || return 1
}

# ------------------------------------------------------------------ resolution

asset_name() { printf 'refinery-%s-%s.%s' "$1" "$TARGET" "$2"; }

# resolve_latest -- newest version that actually has an asset FOR THIS TARGET.
#
# Deliberately not GET /releases/latest: that returns the newest release by date,
# which in this repo is normally an *action* release (v1.x) carrying no binaries.
# The per-target asset filter also means a half-failed pipeline run degrades to the
# previous good version instead of hard-failing one platform.
resolve_latest() {
  local prefix="${1-}" page=1 all="" found
  while [ "$page" -le 3 ]; do
    api_get "$API/repos/$RELEASE_REPO/releases?per_page=100&page=$page" \
      || die "could not list releases of $RELEASE_REPO (HTTP error)"
    found="$(TARGET="$TARGET" jq -r '
      .[]
      | select(.draft == false and .prerelease == false)
      | select(.tag_name | test("^refinery-v[0-9]+\\.[0-9]+\\.[0-9]+$"))
      | { v: (.tag_name | ltrimstr("refinery-v")), names: [.assets[].name] }
      | select(
          .names | any(
            startswith("refinery-\(.v)-" + env.TARGET + ".")
          )
        )
      | .v' "$BODY_FILE")" || die "could not parse the release list"
    all="$all$found"$'\n'
    [ "$(jq 'length' "$BODY_FILE")" -eq 100 ] || break
    page=$((page + 1))
  done

  # Note: no `grep ... || cat` fallback here. grep would have already drained
  # stdin by the time the fallback ran, so the branch must be chosen up front.
  local versions
  versions="$(printf '%s' "$all" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  if [ -n "$prefix" ]; then
    versions="$(printf '%s\n' "$versions" | grep -E "^${prefix//./\\.}(\.|$)" || true)"
  fi
  printf '%s\n' "$versions" | grep -E '^[0-9]' | semver_sort | tail -n1 || true
}

AVAILABLE=""
if ! $PLATFORM_SUPPORTED; then
  info "skipping release lookup: no prebuilt asset exists for $OS/$ARCH"
elif version_is_exact "$VERSION"; then
  info "version $VERSION is exact; resolving without any GitHub API call"
else
  if [ "$VERSION" = latest ]; then
    RESOLVED="$(resolve_latest "")"
    [ -n "$RESOLVED" ] || die "no refinery release in $RELEASE_REPO has an asset for $TARGET"
    info "resolved 'latest' -> $RESOLVED (newest with an asset for $TARGET)"
  else
    RESOLVED="$(resolve_latest "$VERSION")"
    [ -n "$RESOLVED" ] || die "no refinery release matching '$VERSION.*' has an asset for $TARGET"
    info "resolved '$VERSION' -> $RESOLVED (newest ${VERSION}.x with an asset for $TARGET)"
  fi
  VERSION="$RESOLVED"
fi

# ------------------------------------------------------------------ tool cache

TOOL_CACHE="$(to_posix "${RUNNER_TOOL_CACHE:-}")"
TC_ARCH=$([ "$ARCH" = ARM64 ] && printf 'arm64' || printf 'x64')
CACHE_HIT=false

install_root() {
  if [ -n "$TOOL_CACHE" ] && mkdir -p "$TOOL_CACHE" 2>/dev/null && [ -w "$TOOL_CACHE" ]; then
    printf '%s/refinery/%s/%s' "$TOOL_CACHE" "$VERSION" "$TC_ARCH"
  else
    printf '%s/setup-refinery/%s/%s' "$(to_posix "${RUNNER_TEMP:-/tmp}")" "$VERSION" "$TC_ARCH"
  fi
}
DEST="$(install_root)"

# The real hit condition is "this directory holds a runnable refinery", not the
# presence of a marker file -- so a marker-format change in actions/toolkit
# degrades to a cache miss, never to a false hit.
if [ -x "$DEST/refinery$EXE" ]; then
  info "found refinery $VERSION in the tool cache: $DEST"
  CACHE_HIT=true
fi

# ------------------------------------------------------------------ download

WORK="$(mktemp -d "$(to_posix "${RUNNER_TEMP:-/tmp}")/setup-refinery.XXXXXX")"
trap 'rm -rf "$WORK"; rm -f "$HDR_FILE" "$BODY_FILE"' EXIT

BASE="$SERVER/$RELEASE_REPO/releases/download/refinery-v$VERSION"

fetch() {
  curl --proto '=https' --tlsv1.2 -sSfL \
       --retry 3 --retry-all-errors --retry-delay 2 --max-time 300 \
       -o "$2" "$1"
}

# extract_archive <archive> <destdir>
extract_archive() {
  local a="$1" d="$2"
  mkdir -p "$d"
  case "$a" in
    *.tar.gz)
      tar -C "$d" -xzf "$a"
      ;;
    *.zip)
      # Git Bash's `tar` is GNU tar and cannot read zip, and Git for Windows does
      # not reliably ship `unzip`. This is why the pipeline also publishes a
      # .tar.gz for Windows and we prefer it; this path is the belt-and-braces.
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$a" -d "$d"
      elif [ -x "$(to_posix "${SYSTEMROOT:-C:\\Windows}")/System32/tar.exe" ]; then
        "$(to_posix "${SYSTEMROOT:-C:\\Windows}")/System32/tar.exe" \
          -xf "$(to_native "$a")" -C "$(to_native "$d")"
      elif command -v powershell >/dev/null 2>&1; then
        powershell -NoProfile -NonInteractive -Command \
          "Expand-Archive -LiteralPath '$(to_native "$a")' -DestinationPath '$(to_native "$d")' -Force"
      else
        die "no zip extractor available (need unzip, System32\\tar.exe, or powershell)"
      fi
      ;;
    *) die "unrecognised archive type: $a" ;;
  esac
}

download_and_install() {
  local ext asset url got=false
  # Prefer tar.gz on every platform; fall back to .zip only where it is published.
  for ext in "$EXT" zip; do
    asset="$(asset_name "$VERSION" "$ext")"
    url="$BASE/$asset"
    if fetch "$url" "$WORK/$asset" 2>/dev/null; then got=true; break; fi
  done
  $got || return 1

  # Checksums: fail closed. One retry absorbs CDN truncation (a short body does
  # not always make `curl -f` fail); a second mismatch is fatal.
  local attempt=1
  while :; do
    if fetch "$url.sha256" "$WORK/$asset.sha256" 2>/dev/null; then
      :
    elif fetch "$BASE/SHA256SUMS" "$WORK/SHA256SUMS" 2>/dev/null; then
      grep -E "  ?${asset}\$" "$WORK/SHA256SUMS" > "$WORK/$asset.sha256" \
        || die "release refinery-v$VERSION has no checksum entry for $asset"
    else
      die "release refinery-v$VERSION publishes no checksum for $asset; refusing to install unverified binary"
    fi

    if verify_sha256 "$WORK/$asset" "$WORK/$asset.sha256"; then
      info "sha256 verified: $asset"
      break
    fi
    local rc=$?
    [ "$rc" = 2 ] && die "malformed checksum file for $asset"
    if [ "$attempt" = 1 ]; then
      warn "checksum mismatch for $asset; re-downloading once in case of a truncated transfer"
      rm -f "$WORK/$asset" "$WORK/$asset.sha256"
      fetch "$url" "$WORK/$asset" || die "re-download of $asset failed"
      attempt=2
      continue
    fi
    die "$(printf '%s\n%s\n%s' \
      "checksum mismatch for $asset" \
      "  expected $(expected_sha256 "$WORK/$asset.sha256")
  actual   $(sha256_of "$WORK/$asset")
  url      $url" \
      "This can mean a corrupted transfer, an interfering proxy, or a tampered release asset.
Nothing was installed. Please report it at $SERVER/$RELEASE_REPO/issues if it reproduces.")"
  done

  extract_archive "$WORK/$asset" "$WORK/x"

  # Archives are flat, but also carry LICENSE / BUILDINFO.txt / notices, so locate
  # the binary rather than assuming an exact path.
  local bin="$WORK/x/refinery$EXE"
  [ -f "$bin" ] || bin="$(find "$WORK/x" -type f -name "refinery$EXE" -print -quit 2>/dev/null || true)"
  [ -n "$bin" ] && [ -f "$bin" ] || die "archive $asset did not contain refinery$EXE"
  chmod +x "$bin" 2>/dev/null || true

  # Atomic publish so concurrent jobs sharing a self-hosted tool cache can never
  # observe a half-written binary.
  mkdir -p "$DEST"
  local staging="$WORK/staging"
  mkdir -p "$staging"
  cp "$bin" "$staging/refinery$EXE"
  # The licence and notices are a redistribution obligation, so copy them when
  # present -- but do not mask a real copy failure behind `|| true`.
  for extra in LICENSE BUILDINFO.txt THIRD-PARTY-NOTICES.md README.md; do
    if [ -f "$WORK/x/$extra" ]; then
      cp "$WORK/x/$extra" "$staging/$extra"
    fi
  done
  mv -f "$staging/refinery$EXE" "$DEST/refinery$EXE"
  for extra in LICENSE BUILDINFO.txt THIRD-PARTY-NOTICES.md README.md; do
    if [ -f "$staging/$extra" ]; then
      mv -f "$staging/$extra" "$DEST/$extra"
    fi
  done
  # actions/toolkit-compatible marker, so pre-baked self-hosted images interoperate.
  : > "$(dirname "$DEST")/$TC_ARCH.complete" 2>/dev/null || true
  return 0
}

# ------------------------------------------------------------------ fallback

cargo_fallback() {
  command -v cargo >/dev/null 2>&1 || die "$(printf '%s\n%s' \
    "fallback: cargo was requested but there is no cargo on PATH." \
    "Add a Rust toolchain step before this one:
  - uses: dtolnay/rust-toolchain@stable")"

  warn "Building refinery from source: no prebuilt binary for $VERSION/$TARGET. Running 'cargo install refinery_cli --version $VERSION' -- this typically takes 3-10 minutes and is billed as CI time. Pin a prebuilt version to avoid it."
  {
    printf '### :warning: setup-refinery built refinery from source\n\n'
    printf '`refinery %s` had no prebuilt asset for `%s`, so it was compiled with `cargo install`.\n' "$VERSION" "$TARGET"
    printf 'Consider pinning a version that has prebuilt binaries.\n'
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

  if [ "$VERSION" = latest ]; then
    # The per-target asset filter cannot resolve `latest` here, so ask crates.io.
    # It requires a User-Agent or it returns an empty body.
    VERSION="$(curl -sSfL --max-time 30 \
      -A "setup-refinery (+$SERVER/$RELEASE_REPO)" \
      https://crates.io/api/v1/crates/refinery_cli \
      | jq -r '.crate.max_stable_version')" \
      || die "could not resolve 'latest' from crates.io for the cargo fallback"
    [ -n "$VERSION" ] && [ "$VERSION" != null ] \
      || die "crates.io returned no stable version for refinery_cli"
    info "resolved 'latest' -> $VERSION (crates.io max_stable_version)"
    DEST="$(install_root)"
  fi

  local started; started="$(date +%s)"
  group "cargo install refinery_cli $VERSION"
  mkdir -p "$DEST"
  # Default features only, matching the prebuilt assets. Never --all-features:
  # that enables int8-versions, which changes refinery_schema_history semantics.
  if ! cargo install refinery_cli --version "$VERSION" --locked --root "$WORK/cargo"; then
    warn "'cargo install --locked' failed; retrying without --locked"
    cargo install refinery_cli --version "$VERSION" --root "$WORK/cargo" \
      || { endgroup; die "cargo install refinery_cli $VERSION failed"; }
  fi
  endgroup
  cp "$WORK/cargo/bin/refinery$EXE" "$DEST/refinery$EXE"
  info "built refinery $VERSION from source in $(( $(date +%s) - started ))s"
}

# ------------------------------------------------------------------ main

if ! $PLATFORM_SUPPORTED; then
  if [ "$FALLBACK" = cargo ]; then
    cargo_fallback
  else
    die "$(printf '%s\n%s\n%s' \
      "refinery has no prebuilt binary for $OS/$ARCH." \
      "Prebuilt platforms: Linux x64/arm64, macOS x64/arm64, Windows x64." \
      "Build from source instead (slow, needs a Rust toolchain on PATH):
  - uses: dtolnay/rust-toolchain@stable
  - uses: $RELEASE_REPO@v1
    with: { fallback: cargo }")"
  fi
elif ! $CACHE_HIT; then
  if ! download_and_install; then
    # Best effort: only to build a helpful message. If this lookup itself fails
    # (rate limit, offline) we still report the original 404 rather than masking it.
    AVAILABLE="$(resolve_latest "" 2>/dev/null | tail -n5 | tr '\n' ' ' || true)"
    AVAILABLE="${AVAILABLE% }"
    if [ "$FALLBACK" = cargo ]; then
      cargo_fallback
    else
      if [ -n "$AVAILABLE" ]; then
        newest="${AVAILABLE##* }"
        suggestion="pin a version that has a prebuilt binary, e.g. with: { version: '$newest' }"
      else
        suggestion="no prebuilt binaries are published for this platform yet; see $SERVER/$RELEASE_REPO/releases"
      fi
      die "$(printf '%s\n%s\n%s' \
        "no prebuilt refinery binary for version $VERSION on $OS/$ARCH (target $TARGET)." \
        "Versions with an asset for this platform: ${AVAILABLE:-none}" \
        "Options:
  1. $suggestion
  2. build from source (slow, needs a Rust toolchain on PATH):
       - uses: dtolnay/rust-toolchain@stable
       - uses: $RELEASE_REPO@v1
         with: { version: '$VERSION', fallback: cargo }
  3. request a build: $SERVER/$RELEASE_REPO/issues/new")"
    fi
  fi
fi

[ -x "$DEST/refinery$EXE" ] || die "internal error: refinery$EXE missing from $DEST after install"

printf '%s\n' "$(to_native "$DEST")" >> "${GITHUB_PATH:-/dev/null}"
{
  printf 'version=%s\n'   "$VERSION"
  printf 'bin-path=%s\n'  "$(to_native "$DEST/refinery$EXE")"
  printf 'cache-hit=%s\n' "$CACHE_HIT"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

info "installed refinery $VERSION -> $(to_native "$DEST/refinery$EXE")"
