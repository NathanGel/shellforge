#!/bin/zsh
# Shellforge/scripts/test-all.sh — the gate: the helper's pytest suite, the Swift package suite and
# the feedback relay's `node --test`. Runs all three, even after one fails, so one run says
# everything that is wrong, and exits non-zero when any failed. `release.sh` runs it before it
# builds; CI runs the same three suites as jobs of their own.
#
# The helper's tests use `Shellforge/daemon/.venv` when it is there (README: `python3 -m venv .venv
# && .venv/bin/pip install -e '.[dev]'`), else `python3` with the dev extras installed. They write
# no bytecode and no pytest cache: the helper's folder is copied into the app whole, and
# `release.sh` refuses a folder with files git does not track.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failed=()

step() { print -P "%B==> $1%b" }

step "Helper (pytest)"
python="$ROOT/daemon/.venv/bin/python"
[[ -x "$python" ]] || python="$(command -v python3 || true)"
if [[ -z "$python" ]]; then
    print -u2 "test-all: no Python found: make Shellforge/daemon/.venv (see Shellforge/daemon/README.md)"
    failed+=("helper (no Python)")
elif ! (cd "$ROOT/daemon" && PYTHONDONTWRITEBYTECODE=1 "$python" -m pytest -q -p no:cacheprovider); then
    failed+=("helper (pytest)")
fi

step "Swift package (swift test)"
if ! (cd "$ROOT" && scripts/swift.sh test); then
    failed+=("Swift package (swift test)")
fi

step "Feedback relay (node --test)"
if ! command -v node >/dev/null; then
    print -u2 "test-all: node is not installed; the relay needs Node 22 or later"
    failed+=("feedback relay (no node)")
elif ! (cd "$ROOT/feedback-relay" && node --test); then
    failed+=("feedback relay (node --test)")
fi

if (( ${#failed} )); then
    print -u2 ""
    print -u2 "test-all: FAILED: ${(j:, :)failed}"
    exit 1
fi
print ""
print "test-all: all three suites passed"
