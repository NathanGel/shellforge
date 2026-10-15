#!/bin/zsh
# Shellforge/scripts/changelog-notes.sh <version> [changelog] — prints <version>'s section of
# CHANGELOG.md, without its heading: the release notes release.sh publishes. Fails when the version
# has no section, an empty one, or one still headed "unreleased" (date it before releasing).
set -euo pipefail
VERSION="${1:-}"
FILE="${2:-$(cd "$(dirname "$0")/../.." && pwd)/CHANGELOG.md}"
die() { print -u2 "changelog-notes: $*"; exit 1; }
[[ -n "$VERSION" ]] || die "usage: Shellforge/scripts/changelog-notes.sh <version> [changelog]"
[[ -f "$FILE" ]] || die "no $FILE"
heading="$(grep -E "^## ${VERSION//./\\.}( |$)" "$FILE" | head -1 || true)"
[[ -n "$heading" ]] || die "CHANGELOG.md has no \"## $VERSION\" section"
[[ "$heading" != *unreleased* ]] || die "CHANGELOG.md's $VERSION is still \"unreleased\": put its date in the heading"
notes="$(awk -v h="$heading" '$0 == h { on = 1; next } on && /^## / { exit } on' "$FILE" \
    | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"
[[ -n "${notes//[[:space:]]/}" ]] || die "CHANGELOG.md's $VERSION section is empty"
print -r -- "$notes"
