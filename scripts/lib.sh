#!/usr/bin/env bash
# Shared pure-ish helpers for setup-refinery.
#
# Sourced by scripts/setup.sh, scripts/verify.sh and the bats unit tests. Keep every
# function here free of network and filesystem side effects where possible so the
# tests can cover them offline.

# ---------------------------------------------------------------- logging

info()  { printf '%s\n' "$*"; }
warn()  { printf '::warning::%s\n' "$*"; }
group() { printf '::group::%s\n' "$*"; }
endgroup() { printf '::endgroup::\n'; }

# die <message...>  -- emit a GitHub error annotation and exit non-zero.
# Multi-line messages are emitted with %0A so the annotation keeps its line breaks.
die() {
  local msg
  msg="$*"
  printf '::error title=setup-refinery::%s\n' "${msg//$'\n'/%0A}" >&2
  exit 1
}

# ---------------------------------------------------------------- version

# normalize_version <input> -- echo a bare version or the literal "latest".
#
# Accepts:  latest | [vV]N | [vV]N.N | [vV]N.N.N
# Rejects:  everything else, including semver ranges (^0.9, >=0.9) and prereleases.
#
# Ranges are deliberately unsupported: a correct range matcher in shell is a
# liability, and prefix matching ("0.9" -> newest 0.9.x) covers the real need.
# Rejecting now is non-breaking to loosen later; the reverse is not true.
normalize_version() {
  local v="${1-}"
  # Strip all whitespace incl. CR. Windows YAML and ${{ }} interpolation carry \r,
  # which otherwise silently corrupts every downstream comparison and URL.
  v="${v//[$' \t\r\n']/}"
  [ -n "$v" ] || return 1

  # Lowercase without requiring bash 4 ${v,,}
  v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"

  [ "$v" = latest ] && { printf 'latest'; return 0; }

  v="${v#v}"
  case "$v" in
    *[!0-9.]*) return 1 ;;            # any non-digit, non-dot char
  esac
  case "$v" in
    ""|.*|*.|*..*) return 1 ;;        # empty, leading/trailing/double dot
  esac

  local IFS=. parts
  read -r -a parts <<<"$v"
  case "${#parts[@]}" in
    1|2|3) : ;;
    *) return 1 ;;
  esac
  printf '%s' "$v"
}

# version_is_exact <normalized> -- true when all three components are present,
# which is the case that needs zero GitHub API calls.
version_is_exact() {
  case "${1-}" in
    *.*.*) [ "$(normalize_version "$1")" = "$1" ] ;;
    *) return 1 ;;
  esac
}

# semver_sort -- read versions on stdin, emit ascending. Correct numeric sort
# because callers only ever feed it X.Y.Z with no prerelease suffix.
semver_sort() { sort -t. -k1,1n -k2,2n -k3,3n; }

# ---------------------------------------------------------------- platform

# detect_os / detect_arch -- prefer the runner-provided values, fall back to uname
# for self-hosted and container runners that do not set them.
detect_os() {
  if [ -n "${RUNNER_OS-}" ]; then printf '%s' "$RUNNER_OS"; return; fi
  case "$(uname -s)" in
    Linux) printf 'Linux' ;;
    Darwin) printf 'macOS' ;;
    CYGWIN*|MINGW*|MSYS*|Windows_NT) printf 'Windows' ;;
    *) printf 'unknown' ;;
  esac
}

detect_arch() {
  if [ -n "${RUNNER_ARCH-}" ]; then printf '%s' "$RUNNER_ARCH"; return; fi
  case "$(uname -m)" in
    x86_64|amd64) printf 'X64' ;;
    aarch64|arm64) printf 'ARM64' ;;
    armv7l|armv6l) printf 'ARM' ;;
    i686|i386) printf 'X86' ;;
    *) printf 'unknown' ;;
  esac
}

# map_target <os> <arch> -- echo "<triple> <ext> <exe> <note>" or return 1.
#
# Kept in sync with .github/targets.json by scripts/check-targets.sh in CI, so the
# producer and the consumer can never disagree about an asset name.
map_target() {
  local os="${1-}" arch="${2-}"
  case "$os:$arch" in
    Linux:X64)     printf 'x86_64-unknown-linux-musl tar.gz  ' ;;
    Linux:ARM64)   printf 'aarch64-unknown-linux-musl tar.gz  ' ;;
    macOS:ARM64)   printf 'aarch64-apple-darwin tar.gz  ' ;;
    macOS:X64)     printf 'x86_64-apple-darwin tar.gz  ' ;;
    Windows:X64)   printf 'x86_64-pc-windows-msvc tar.gz .exe ' ;;
    # No native windows-arm64 build. Windows 11 / Server 2025 on ARM run x64
    # binaries under emulation, so install the x64 asset and say so. The separate
    # verify step turns a wrong guess here into an immediate, attributed failure.
    Windows:ARM64) printf 'x86_64-pc-windows-msvc tar.gz .exe emulated' ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- paths

# Windows runners hand out backslash paths (D:\a\_temp) that Git Bash cannot use,
# while $GITHUB_PATH and step outputs must receive NATIVE paths or the PATH prepend
# silently does nothing. Convert at every boundary.
to_posix() {
  if [ "$(detect_os)" = Windows ] && command -v cygpath >/dev/null 2>&1
  then cygpath -u "$1"; else printf '%s' "$1"; fi
}
to_native() {
  if [ "$(detect_os)" = Windows ] && command -v cygpath >/dev/null 2>&1
  then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# ---------------------------------------------------------------- checksums

# sha256_of <file> -- lowercase hex digest. Tool availability genuinely differs:
# Linux has GNU sha256sum, macOS ships shasum but not sha256sum, Git Bash and
# Windows fall back to openssl or certutil.
sha256_of() {
  local f="$1" h=
  if   command -v sha256sum >/dev/null 2>&1; then h=$(sha256sum "$f" | awk '{print $1}')
  elif command -v shasum    >/dev/null 2>&1; then h=$(shasum -a 256 "$f" | awk '{print $1}')
  elif command -v openssl   >/dev/null 2>&1; then h=$(openssl dgst -sha256 "$f" | awk '{print $NF}')
  elif command -v certutil  >/dev/null 2>&1; then
    h=$(certutil -hashfile "$(to_native "$f")" SHA256 | sed -n 2p | tr -d ' \r')
  else
    die "no SHA-256 tool available (need one of: sha256sum, shasum, openssl, certutil)"
  fi
  printf '%s' "$h" | tr '[:upper:]' '[:lower:]'
}

# expected_sha256 <sidecar-file> -- first field of a `sha256sum`-format line.
expected_sha256() {
  local want
  want=$(tr -d '\r' < "$1" | awk 'NF{print tolower($1); exit}')
  [ ${#want} -eq 64 ] || return 1
  case "$want" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s' "$want"
}

# verify_sha256 <file> <sidecar> -- true on match. Callers decide the policy
# (one retry, then fail closed). There is deliberately no override.
verify_sha256() {
  local want got
  want=$(expected_sha256 "$2") || return 2   # 2 = malformed sidecar
  got=$(sha256_of "$1")
  [ "$want" = "$got" ]
}
