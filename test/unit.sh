#!/usr/bin/env bash
# Unit tests for the pure helpers in scripts/lib.sh.
#
# Plain bash rather than bats: no install step, so it runs identically on a
# contributor's laptop, on all five CI runners, and under act.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "$ROOT/scripts/lib.sh"

PASS=0; FAIL=0

eq() { # eq <expected> <actual> <label>
  if [ "$1" = "$2" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); printf 'FAIL %s\n  expected: %q\n  actual:   %q\n' "$3" "$1" "$2"; fi
}
ok() { # ok <label> <cmd...>  -- expect success
  if "${@:2}" >/dev/null 2>&1; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); printf 'FAIL %s (expected success)\n' "$1"; fi
}
no() { # no <label> <cmd...>  -- expect failure
  if "${@:2}" >/dev/null 2>&1; then FAIL=$((FAIL+1)); printf 'FAIL %s (expected failure)\n' "$1";
  else PASS=$((PASS+1)); fi
}

printf '# normalize_version\n'
eq '0.9.2'  "$(normalize_version '0.9.2')"   'plain'
eq '0.9.2'  "$(normalize_version 'v0.9.2')"  'v prefix'
eq '0.9.2'  "$(normalize_version 'V0.9.2')"  'V prefix'
eq '0.9.2'  "$(normalize_version '  0.9.2 ')" 'surrounding spaces'
eq '0.9.2'  "$(normalize_version "0.9.2$(printf '\r')")" 'trailing CR from Windows YAML'
eq 'latest' "$(normalize_version 'latest')"  'latest'
eq 'latest' "$(normalize_version 'LATEST')"  'LATEST'
eq '0.9'    "$(normalize_version '0.9')"     'partial minor'
eq '0'      "$(normalize_version '0')"       'major only'
for bad in '^0.9' '>=0.9' '0.9.2-rc1' '1.0.0+build' 'banana' '' ' ' '0..9' '.9' '9.' '0.9.2.1' 'v' 'latest2'; do
  no "reject '$bad'" normalize_version "$bad"
done

printf '# version_is_exact\n'
ok  'exact 0.9.2'       version_is_exact '0.9.2'
no  'partial 0.9'       version_is_exact '0.9'
no  'latest'            version_is_exact 'latest'

printf '# semver_sort\n'
eq '0.9.2 0.9.10 0.10.0 1.0.0' \
   "$(printf '1.0.0\n0.10.0\n0.9.2\n0.9.10\n' | semver_sort | tr '\n' ' ' | sed 's/ $//')" \
   'numeric, not lexicographic'

printf '# map_target (all 5 supported + emulated + unsupported)\n'
eq 'x86_64-unknown-linux-musl'  "$(map_target Linux X64   | awk '{print $1}')" 'linux x64'
eq 'aarch64-unknown-linux-musl' "$(map_target Linux ARM64 | awk '{print $1}')" 'linux arm64'
eq 'aarch64-apple-darwin'       "$(map_target macOS ARM64 | awk '{print $1}')" 'macos arm64'
eq 'x86_64-apple-darwin'        "$(map_target macOS X64   | awk '{print $1}')" 'macos x64'
eq 'x86_64-pc-windows-msvc'     "$(map_target Windows X64 | awk '{print $1}')" 'windows x64'
eq '.exe'     "$(map_target Windows X64 | awk '{print $3}')" 'windows exe suffix'
eq 'emulated' "$(map_target Windows ARM64 | awk '{print $4}')" 'windows arm64 is flagged emulated'
for bad in 'Linux ARM' 'Linux X86' 'macOS ARM' 'Solaris X64' ': '; do
  # shellcheck disable=SC2086
  no "unsupported '$bad'" map_target $bad
done

printf '# map_target agrees with .github/targets.json\n'
while read -r target os arch ext exe; do
  got="$(map_target "$os" "$arch")" || { FAIL=$((FAIL+1)); printf 'FAIL targets.json %s not mapped\n' "$target"; continue; }
  eq "$target" "$(printf '%s' "$got" | awk '{print $1}')" "targets.json $os/$arch -> triple"
  eq "$ext"    "$(printf '%s' "$got" | awk '{print $2}')" "targets.json $target -> ext"
  eq "$exe"    "$(printf '%s' "$got" | awk '{print $3}')" "targets.json $target -> exe"
done < <(jq -r '.targets[] | "\(.target) \(.runner_os) \(.runner_arch) \(.ext) \(.exe)"' "$ROOT/.github/targets.json")

printf '# checksums\n'
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf 'refinery' > "$TMP/f"
KNOWN="$(printf 'refinery' | sha256sum | awk '{print $1}')"
eq "$KNOWN" "$(sha256_of "$TMP/f")" 'sha256_of matches sha256sum'
printf '%s  f\n' "$KNOWN" > "$TMP/f.sha256"
ok 'verify_sha256 accepts a good sidecar' verify_sha256 "$TMP/f" "$TMP/f.sha256"
# Uppercase digests and CRLF line endings both occur in the wild.
printf '%s  f\r\n' "$(printf '%s' "$KNOWN" | tr 'a-f' 'A-F')" > "$TMP/f.upper"
ok 'verify_sha256 tolerates uppercase + CRLF' verify_sha256 "$TMP/f" "$TMP/f.upper"
printf '%s  f\n' "$(printf '%064d' 0)" > "$TMP/f.bad"
no 'verify_sha256 rejects a wrong digest' verify_sha256 "$TMP/f" "$TMP/f.bad"
printf 'not-a-digest  f\n' > "$TMP/f.malformed"
no 'expected_sha256 rejects a malformed sidecar' expected_sha256 "$TMP/f.malformed"

printf '# release selection (scripts/select-versions.jq)\n'
# Recorded fixtures are the only way to cover "release exists but this target's
# asset is missing" -- impossible to produce against the live API.
FIX="$ROOT/test/fixtures/releases.json"
sel() { TARGET="$1" jq -r -f "$ROOT/scripts/select-versions.jq" "$FIX" | semver_sort | tr '\n' ' ' | sed 's/ $//'; }

# Sorted ascending, so the last entry is what `latest` resolves to.
eq '0.9.1 0.9.2 0.9.10 0.10.0' "$(sel x86_64-unknown-linux-musl)" 'linux x64: all versions with that asset'
# 0.9.2 has no aarch64-linux asset, so this platform must fall back to 0.9.1
# rather than hard-failing. This is the graceful-degradation property.
eq '0.9.1'                     "$(sel aarch64-unknown-linux-musl)" 'linux arm64: degrades to 0.9.1'
eq '0.9.2'                     "$(sel aarch64-apple-darwin)"       'macos arm64: only 0.9.2'
# Windows publishes .zip as well as .tar.gz; either satisfies the filter.
eq '0.9.2'                     "$(sel x86_64-pc-windows-msvc)"     'windows: .zip counts'
eq ''                          "$(sel x86_64-apple-darwin)"        'macos x64: nothing published'

# Exclusions, each a real failure mode:
sel_all="$(sel x86_64-unknown-linux-musl)"
case "$sel_all" in
  *1.0.0*|*1.1.0*) FAIL=$((FAIL+1)); printf 'FAIL action releases (v1.x) must never be selected\n' ;;
  *) PASS=$((PASS+1)) ;;
esac
case "$sel_all" in
  *0.9.0*) FAIL=$((FAIL+1)); printf 'FAIL draft releases must be excluded\n' ;;
  *) PASS=$((PASS+1)) ;;
esac
case "$sel_all" in
  *0.8.16*) FAIL=$((FAIL+1)); printf 'FAIL prereleases must be excluded\n' ;;
  *) PASS=$((PASS+1)) ;;
esac
# 0.8.14 has ONLY a .sha256 sidecar, no archive -- a sidecar must not count.
case "$sel_all" in
  *0.8.14*) FAIL=$((FAIL+1)); printf 'FAIL a lone .sha256 sidecar must not count as an asset\n' ;;
  *) PASS=$((PASS+1)) ;;
esac
# And the ordering trap: 0.9.10 > 0.9.9, 0.10.0 > 0.9.x
eq '0.10.0' "$(sel x86_64-unknown-linux-musl | tr ' ' '\n' | semver_sort | tail -n1)" \
   'latest picks 0.10.0, not 0.9.2 (numeric sort)'

printf '\n%s\n' "-----------------------------"
printf 'pass=%d fail=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
