# M4m A clean environment for every tab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Every tab's commands behave as they do in a terminal opened from the Dock, however Shellforge was started.

**Finding (14 October 2026):** Shellforge was opened with `open` from inside a Claude Code session, so it inherited that session's markers. Every tab got them: `CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID`, and a messaging socket and token. A `claude` started in a tab then took itself for that session's child and turned transcript saving off. iTerm2 hands its own environment to every session, and Shellforge's login-shell read starts from it too.

## Global Constraints
- **Removed, at launch, from Shellforge's own environment, before any window or shell starts:**
  - Claude Code's session markers: `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_CODE_EXECPATH`, `CLAUDE_CODE_SSE_PORT`, `CLAUDE_PID`, `CLAUDE_EFFORT`;
  - `AI_AGENT`.
- **Kept:** a person's own settings, such as `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CONFIG_DIR` and `CODEX_HOME`.
- From now on, Shellforge is launched from a session with `env -i`, so it starts as it would from the Dock.
- macOS 13; commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.

## Review Focus
1. **A restored window's shells.** Expected: they start after the scrub, so they get none of the markers.
2. **A setting someone exports in `.zshrc`.** Expected: untouched, because the tab's login shell sets it again.

---

### Task 1: Scrub inherited agent markers
- `InheritedEnvironment.agentMarkers(in:) -> [String]` (Core, pure) names the markers present.
- `iTermShellforgeSidebar.scrubInheritedEnvironment()` unsets them. The app delegate calls it first thing in `applicationWillFinishLaunching`.
- Tests:
  - `agentSessionMarkersAreNamed`
  - `aPersonsOwnSettingsAreKept`

### Task 2: Verify
- Build; the package and `ShellforgeHostTest` pass.
- Relaunched as the parent session would launch it, a new tab's `env` shows no marker.
