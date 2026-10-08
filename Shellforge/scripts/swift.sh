#!/bin/zsh
# Resolves the Swift toolchain every Shellforge build command uses: the release `.swift-version` pins,
# by major.minor. An older compiler fails on the package; a newer one would build what the pinned
# one, and so the release, may not.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pinned="$(sed -nE 's/^([0-9]+\.[0-9]+).*/\1/p' "$ROOT/.swift-version")"
candidate="${SWIFT:-$HOME/.swiftly/bin/swift}"

if [[ -z "$pinned" ]]; then
    print -u2 "No major.minor Swift version in $ROOT/.swift-version"
    exit 1
fi

if [[ ! -x "$candidate" ]]; then
    print -u2 "Shellforge requires Swift $pinned. Install it with:"
    print -u2 "  ~/.swiftly/bin/swiftly install --use $pinned"
    print -u2 "No executable Swift toolchain found at: $candidate"
    exit 1
fi

version_output="$("$candidate" --version 2>&1)"
version="$(print -r -- "$version_output" | sed -nE 's/^.*Swift version ([0-9]+)\.([0-9]+).*$/\1.\2/p' | head -n 1)"

if [[ "$version" != "$pinned" ]]; then
    print -u2 "Shellforge requires Swift $pinned. Found: ${version:-unknown} at $candidate"
    print -u2 "Install and select it with: ~/.swiftly/bin/swiftly install --use $pinned"
    exit 1
fi

exec "$candidate" "$@"
