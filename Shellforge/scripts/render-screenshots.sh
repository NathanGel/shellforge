#!/bin/zsh
# Draws the README's screenshots from code, with made-up projects, tasks and readings
# (Tests/ShellforgeUITests/ReadmeScreenshots.swift), into docs/images/. Nothing of the machine it
# runs on — its projects, defaults, Keychain or ~/.ssh/config — is read. Run it after a change to
# the sidebar, the Metrics panel, Rearrange mode or the New Task sheet, then commit the PNGs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/images"
mkdir -p "$OUT"

cd "$ROOT"
SHELLFORGE_RENDER_SCREENSHOTS=1 SHELLFORGE_SCREENSHOTS_DIR="$OUT" "$ROOT/scripts/swift.sh" test --filter ReadmeScreenshots

print "Screenshots written to $OUT:"
ls -1 "$OUT"/*.png
