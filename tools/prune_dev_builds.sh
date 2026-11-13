#!/bin/zsh
# tools/prune_dev_builds.sh [-n] — removes what a deleted checkout or worktree left behind.
#
# Every checkout of this repository gets its own Xcode DerivedData folder (iTerm2-<hash>, about
# 5 GB) and, once `make run` has launched it, its own dev suite (<folder name>-dev: a folder in
# Application Support and two defaults domains). Removing the worktree removes none of these.
# This finds the DerivedData folders whose project no longer exists and removes each one along
# with its checkout's dev suite. Anything still in use (a running build, a suite's live
# session server) is skipped and reported, so a later run gets it.
#
# The Makefile runs this before every Development build. -n lists what would go and removes nothing.
set -uo pipefail

DRY=0
[[ "${1:-}" == -n ]] && DRY=1
DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
SUPPORT="$HOME/Library/Application Support"
PREFS="$HOME/Library/Preferences"

# Folder names of the checkouts that still exist: a suite one of them uses is never removed.
live_names=()
for wt in ${(f)"$(git -C "${0:A:h}/.." worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"}; do
    live_names+=("${wt:t:l}")
done

remove() {
    if (( DRY )); then print "prune: would remove $1"; else rm -rf -- "$1" && print "prune: removed $1"; fi
}

in_use() { pgrep -f -- "$1" >/dev/null }

for dir in "$DERIVED"/iTerm2-*(N/); do
    project="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$dir/info.plist" 2>/dev/null)" || continue
    [[ "${project:t}" == iTerm2.xcodeproj && ! -e "$project" ]] || continue
    checkout="${project:h:t}"
    suite="$checkout-dev"
    # The DerivedData folder is how a later run finds the suite, so both stay until neither is in use.
    if in_use "$dir/" || in_use "-suite $suite( |$)" || in_use "$SUPPORT/$suite/"; then
        print "prune: skipped $dir and the $suite suite: they are in use"
        continue
    fi
    remove "$dir"

    # Another checkout with the same folder name shares the suite.
    (( ${live_names[(Ie)${checkout:l}]} )) && continue
    [[ -d "$SUPPORT/$suite" ]] && remove "$SUPPORT/$suite"
    for domain in "$suite" "$suite.private"; do
        [[ -e "$PREFS/$domain.plist" ]] || continue
        if (( DRY )); then
            print "prune: would delete the $domain defaults"
        else
            defaults delete "$domain" >/dev/null 2>&1
            rm -f -- "$PREFS/$domain.plist"
            print "prune: deleted the $domain defaults"
        fi
    done
done
exit 0
