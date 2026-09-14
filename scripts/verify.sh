#!/usr/bin/env bash
# Prove that `refinery` is genuinely on PATH and runnable.
#
# This MUST be a separate action.yml step from setup.sh: writes to $GITHUB_PATH do
# not affect the step that made them, so this is the only place the PATH prepend
# can actually be observed. It also turns a wrong-architecture asset ("exec format
# error") into a failure attributed to this action rather than a mystery three
# steps later in the consumer's workflow.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

command -v refinery >/dev/null 2>&1 \
  || die "refinery is not on PATH after installation (expected version ${EXPECTED_VERSION:-unknown})"

# clap guarantees --help, so this is the pass/fail gate: it proves the binary
# loads and executes on this architecture.
refinery migrate --help >/dev/null \
  || die "'refinery migrate --help' failed; the installed binary is not runnable on $(detect_os)/$(detect_arch)"

# refinery_cli declares #[clap(version)], so --version is reliable. Exact-matching
# it is what catches a MISLABELLED asset -- e.g. a release job that uploaded 0.9.1
# bits under a 0.9.2 filename.
if [ -n "${EXPECTED_VERSION-}" ]; then
  actual="$(refinery --version 2>/dev/null | tr -d '\r' || true)"
  case "$actual" in
    *"$EXPECTED_VERSION"*)
      info "verified: $actual on PATH"
      ;;
    "")
      warn "'refinery --version' produced no output; skipping the version cross-check"
      ;;
    *)
      die "$(printf '%s\n%s' \
        "installed binary reports '$actual' but $EXPECTED_VERSION was requested." \
        "This usually means a release asset is mislabelled. Please report it.")"
      ;;
  esac
else
  info "verified: refinery is on PATH"
fi
