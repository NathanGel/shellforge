#!/bin/zsh
# Ported from AiTerm (scripts/release.sh), GPLv3, Laurens D'Hondt.
# Shellforge/scripts/release.sh <version> — builds Shellforge <version>, signs it with the
# "Shellforge Release" certificate, wraps it in a DMG and publishes the GitHub release that
# Shellforge › Check for Updates… reads. Run from a clean master that matches origin/master.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${1:-}"
REPO="NathanGel/shellforge"
IDENTITY="${SIGN_IDENTITY:-Shellforge Release}"
APP="$ROOT/build/Shellforge.app"
DMG="$ROOT/build/Shellforge-$VERSION.dmg"

die() { print -u2 "release: $*"; exit 1; }

# Canonical numbers only: the updater reads 01.2.3 as 1.2.3 and would look for an image not there.
[[ "$VERSION" =~ '^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$' ]] || die "usage: Shellforge/scripts/release.sh <major.minor.patch>, no leading zeros"
cd "$ROOT"
[[ "$(git branch --show-current)" == master ]] || die "run from master"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "the working tree has uncommitted changes"
# The helper is copied into the app as a whole folder: nothing in it may be absent from the tag.
[[ -z "$(git status --porcelain --ignored -- Shellforge/daemon/shellforged)" ]] || die "Shellforge/daemon/shellforged has files git does not track (git clean -ndX -- Shellforge/daemon/shellforged)"
origin="$(git remote get-url origin)"
[[ "$origin" == (git@github.com:|https://github.com/|ssh://git@github.com/)"$REPO"(.git|) ]] || die "origin is $origin, not github.com/$REPO"
git fetch --quiet --tags origin master
[[ "$(git rev-parse master)" == "$(git rev-parse origin/master)" ]] || die "master is not the same as origin/master"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && die "v$VERSION already exists"
gh auth status --hostname github.com >/dev/null 2>&1 || die "gh is not logged in to github.com (gh auth login)"
# Shellforge's versions are its GitHub releases: the repository also holds iTerm2's own tags
# (v3.7.4, v20261013-nightly), which are no Shellforge version.
released="$(gh release list --repo "$REPO" --limit 1000 --json tagName -q '.[].tagName' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)"
latest="$(print -r -- "$released" | sed -n 's/^v//p' | sort -V | tail -1)"
if [[ -n "$latest" ]]; then
    newest="$(printf '%s\n%s\n' "$latest" "$VERSION" | sort -V | tail -1)"
    [[ "$newest" == "$VERSION" && "$latest" != "$VERSION" ]] || die "$VERSION is not newer than $latest"
fi
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || die "no \"$IDENTITY\" code-signing certificate in the keychain (see Shellforge/docs/releasing.md)"

# One more than Shellforge's releases so far: every install sees the number grow.
BUILD=$(( $(print -r -- "$released" | grep -c . || true) + 1 ))
SHELLFORGE_RELEASE=1 SHELLFORGE_VERSION="$VERSION" SHELLFORGE_BUILD="$BUILD" SIGN_IDENTITY="$IDENTITY" "$ROOT/Shellforge/scripts/make-app.sh"
/usr/libexec/PlistBuddy -c 'Print :ShellforgeDevBuild' "$APP/Contents/Info.plist" >/dev/null 2>&1 && die "the bundle is marked as a dev build"
codesign -d -r- "$APP" 2>/dev/null | grep -q '^designated => .*certificate leaf' || die "the bundle is not certificate-signed"
"$ROOT/Shellforge/scripts/make-dmg.sh" "$APP" "$DMG"

git tag -a "v$VERSION" -m "Shellforge $VERSION"
git push --quiet origin "v$VERSION"
# A draft first, so the release goes public only with its image attached: updaters never see a
# draft, and a run that stops here is finished by hand (Shellforge/docs/releasing.md).
gh release create "v$VERSION" "$DMG" --repo "$REPO" --draft --verify-tag --title "Shellforge $VERSION" --generate-notes
gh release edit "v$VERSION" --repo "$REPO" --draft=false >/dev/null
print "released Shellforge $VERSION (build $BUILD): https://github.com/$REPO/releases/tag/v$VERSION"
