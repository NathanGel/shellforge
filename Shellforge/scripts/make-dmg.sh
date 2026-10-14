#!/bin/zsh
# Ported from AiTerm (scripts/make-dmg.sh), GPLv3, Laurens D'Hondt.
# Shellforge/scripts/make-dmg.sh <Shellforge.app> <output.dmg> — wraps a built app in a
# drag-to-Applications disk image and checks what it wrote. Built with macOS's own hdiutil, so it
# needs nothing downloaded (AiTerm's dmgbuild comes from PyPI).
set -euo pipefail
APP="${1:-}" DMG="${2:-}"

die() { print -u2 "make-dmg: $*"; exit 1; }

[[ -n "$APP" && -n "$DMG" ]] || die "usage: make-dmg.sh <Shellforge.app> <output.dmg>"
APP="${APP:A}"
[[ -d "$APP" && "${APP:t}" == Shellforge.app ]] || die "expected a path to Shellforge.app, got $APP"

STAGE="$(mktemp -d)"
MOUNT="$(mktemp -d)"
trap 'hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true; rm -rf "$STAGE"; rmdir "$MOUNT" 2>/dev/null || true' EXIT
ditto "$APP" "$STAGE/Shellforge.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "${DMG:h}"
rm -f "$DMG"
hdiutil create -quiet -volname Shellforge -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG"

hdiutil verify -quiet "$DMG" || die "the image does not verify"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG"
codesign --verify --deep --strict "$MOUNT/Shellforge.app" || die "the app inside the image does not verify"
[[ "$(readlink "$MOUNT/Applications")" == /Applications ]] || die "the image has no link to /Applications"
want="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
got="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT/Shellforge.app/Contents/Info.plist")"
[[ "$got" == "$want" ]] || die "the image holds Shellforge $got, not $want"
print "built $DMG"
