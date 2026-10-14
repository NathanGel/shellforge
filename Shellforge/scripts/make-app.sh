#!/bin/zsh
# Ported from AiTerm (scripts/make-app.sh), GPLv3, Laurens D'Hondt.
# Shellforge/scripts/make-app.sh — builds build/Shellforge.app: iTerm2's Deployment configuration,
# for Apple silicon, signed with the "Shellforge Release" certificate when the keychain has it,
# else ad hoc. Run from anywhere; the build goes in <repo>/build/.
#
#   SHELLFORGE_RELEASE=1   a release: no ShellforgeDevBuild key, so Check for Updates… works
#   SHELLFORGE_VERSION=x.y.z, SHELLFORGE_BUILD=n   stamped into the bundle (release.sh sets them)
#   SIGN_IDENTITY=…        another certificate; "-" forces ad-hoc signing
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build"
DERIVED="$OUT/DerivedData-release"
APP="$OUT/Shellforge.app"
LOG="$OUT/xcodebuild-release.log"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    security find-identity -p codesigning | grep -q '"Shellforge Release"' && SIGN_IDENTITY="Shellforge Release" || SIGN_IDENTITY="-"
fi

die() { print -u2 "make-app: $*"; exit 1; }

mkdir -p "$OUT"
cd "$ROOT"
# A fresh clone has neither: the Makefile's own first step, and git's.
[[ -f plists/iTerm2.plist ]] || cp plists/dev-iTerm2.plist plists/iTerm2.plist
if git submodule status | grep -q '^-'; then
    die "submodules are not checked out: git submodule update --init --recursive"
fi
# Xcode signs nothing: iTerm2's Deployment configuration asks for its own team's profile. The
# whole bundle is signed below, once, with Shellforge's certificate.
if ! xcodebuild -project iTerm2.xcodeproj -scheme iTerm2 -configuration Deployment -skipPackagePluginValidation \
        -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
        build >"$LOG" 2>&1; then
    tail -50 "$LOG" >&2
    die "the build failed; the whole log is $LOG"
fi
tail -1 "$LOG"

rm -rf "$APP"
ditto "$DERIVED/Build/Products/Deployment/iTerm2.app" "$APP"
# Bytecode caches are this machine's, not the source's.
find "$APP/Contents/Resources/daemon" -name __pycache__ -type d -prune -exec rm -rf {} +
PLIST="$APP/Contents/Info.plist"
if [[ -n "${SHELLFORGE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHELLFORGE_VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${SHELLFORGE_BUILD:-1}" "$PLIST"
fi
# Stamped here, not left to plists/iTerm2.plist: that file is a local, gitignored copy of
# dev-iTerm2.plist, and an old copy lacks the feed — a release without it could never update.
/usr/libexec/PlistBuddy -c 'Delete :ShellforgeUpdateFeed' "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :ShellforgeUpdateFeed string github:NathanGel/shellforge' "$PLIST"
/usr/libexec/PlistBuddy -c 'Delete :ShellforgeDevBuild' "$PLIST" 2>/dev/null || true
if [[ "${SHELLFORGE_RELEASE:-}" != 1 ]]; then
    /usr/libexec/PlistBuddy -c 'Add :ShellforgeDevBuild bool true' "$PLIST"
fi

# iTerm2's entitlements, less the two that name Apple's iTerm2 team, which no other certificate has.
ENTITLEMENTS="$OUT/Shellforge.entitlements"
cp "$ROOT/iTerm2.entitlements" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.application-groups' "$ENTITLEMENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$ENTITLEMENTS" 2>/dev/null || true
# The nested code first, then the app itself with its entitlements.
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP" || die "the signed app does not verify"

[[ -d "$APP/Contents/Resources/daemon/shellforged" ]] || die "the bundle has no helper"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == io.github.nathangel.shellforge ]] || die "wrong bundle id"
print "built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST"), signed: $SIGN_IDENTITY$( [[ "${SHELLFORGE_RELEASE:-}" == 1 ]] || print ', dev build'))"
