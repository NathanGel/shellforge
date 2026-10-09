#!/bin/zsh -f
# hooks/claude-statusline-shim.sh — installed as Claude Code's statusLine command by AiTerm.
# 1. forwards the statusline JSON to the AiTerm daemon (fire and forget, 300 ms cap)
# 2. preserves a previously configured status line, otherwise prints nothing.
# The statusLine callback supplies the usage payload. AiTerm uses it as a telemetry bridge,
# without adding its own terminal display or requiring a display preference.
# Claude Code runs this on every tick, so it starts nothing it can avoid: `-f` keeps zsh from
# sourcing the user's rc files, stdin is read with a builtin rather than a forked `cat`, and the
# two things it needs are plain-text files ClaudeDriver writes in the support folder: the hook port
# (AiTermPaths.hookPortURL; no port, or anything but one, no post) and the user's original
# command, run through `sh -c` as the agent itself would run it. The builtin `read` takes its
# input a byte at a time, so it costs more than the `cat` fork it replaces once a payload passes
# about 10 KB (33 ms against 10 ms at 60 KB, measured); a tick's payload is a few KB.
# The redirection wraps the whole backgrounded pipeline, not just curl: a redirection written after
# only the last command leaves printf's stderr pointed at this script's own — a grandchild holding
# that pipe open past the parent's exit, exactly the pattern ProcessRunner.swift warns about.
set -u
IFS= read -r -d '' INPUT || true
SUPPORT="$HOME/Library/Application Support/AiTerm"
PORT=""
[ -f "$SUPPORT/hook-port" ] && { PORT="$(<"$SUPPORT/hook-port")" 2>/dev/null; }
# Only a port, 1-65535 in digits, goes into the URL: a zsh pattern, so the check forks nothing.
if [[ $PORT == <1-65535> ]]; then
  { printf '%s' "$INPUT" | curl -s -m 0.3 -X POST -H 'Content-Type: application/json' -H 'X-AiTerm-Hook: 1' -H 'Expect:' --data-binary @- "http://127.0.0.1:$PORT/statusline"; } >/dev/null 2>&1 &
fi
ORIG_FILE="$SUPPORT/statusline-original.cmd"
if [ -f "$ORIG_FILE" ]; then
  ORIG_CMD="$(<"$ORIG_FILE")" 2>/dev/null
  if [ -n "$ORIG_CMD" ]; then printf '%s' "$INPUT" | /bin/sh -c "$ORIG_CMD"; exit $?; fi
fi
exit 0
