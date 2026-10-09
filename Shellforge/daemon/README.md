shellforged drives iTerm2 for AiTerm. Run with `python -m shellforged run`; poke it with
`python -m shellforged ctl iterm.status`. Tests: `.venv/bin/pytest -q`. Live tests
against a running iTerm2: `AITERMD_LIVE=1 .venv/bin/pytest tests/integration -q`.

## App connection

`workspace.snapshot` returns protocol version 1, iTerm2 availability, tagged sessions, and
usage. The server writes this response before yielding; the Swift client places it in its
event stream as a bootstrap barrier. Events before the barrier are discarded. A disconnected
snapshot does not prove any window closed. Event overflow or malformed framing closes the
connection so the app can bootstrap again. Frames are limited to 1 MiB; slow client writes
have a two-second drain deadline. Swift requests time out after 15 seconds and can be canceled.

`window.createTask` serializes creation and checks existing tagged sessions first. Retrying
the same task ID returns its existing window without replaying an agent command. This works
after a helper restart because tags live in iTerm2. The app refuses incompatible snapshots
and does not terminate a helper it adopted from another app process.

Hook events report agent activity only. The helper does not rewrite shell commands, schedule
checkout deletion, or close windows after Stop. Cleanup is an explicit app action.

## Hook receiver

The daemon listens on `127.0.0.1:<hookPort>` (default 47821) for seven POST
routes, used by the installed Claude Code / Codex / Grok Build command hooks,
the PI extension and the two statusline shims:

- `POST /hook/claude` — Claude Code hook events (`SessionStart`,
  `PostModelSwitch`, `UserPromptSubmit`, `SubagentStart`, `SubagentStop`,
  `Stop`, `Notification`, `PermissionRequest`).
- `POST /hook/codex` — Codex hook events (`SessionStart`, `UserPromptSubmit`,
  `SubagentStart`, `SubagentStop`, `PermissionRequest`).
- `POST /hook/grok` — Grok Build command hooks (`SessionStart`,
  `UserPromptSubmit`, `Notification` (`permission_prompt`, `idle_prompt`),
  `PostToolUse`, `PostToolUseFailure`, `Stop`, `StopFailure`,
  `StopCancelled`).
- `POST /hook/pi` — PI extension events (`session_start`, `agent_start`,
  `agent_settled`, `ui_prompt_start`, `ui_prompt_end`, `model_select`,
  `thinking_level_select`).
- `POST /mcp` — the stateless MCP bridge for Codex's final `Stop` hook. It
  remains reachable after a merge removes the session's working directory.
- `POST /statusline` — the Claude Code statusline shim's forwarded JSON.
- `POST /statusline/grok` — the Grok status-line shim's forwarded JSON
  (model, effort, context; Grok has no rate-limit block, so this route never
  touches the `UsageStore`).

Grok's own command hooks are the one transport in this list that spawns a
process in the session's cwd, so they are also the one that goes silent when
an agent's last turn removes its own worktree. The daemon's tick settles that
case rather than trusting a hook that can no longer arrive: an agent session
stuck `working` or `needsInput` whose directory has been missing for 10
seconds (`StatusEngine.settle_orphans`, `ORPHAN_SETTLE_SECONDS`) is forced to
`done`, unless its transport survives a removed cwd — Claude, Codex and PI are
exempt (`end_of_turn_survives_cwd_loss` in the `HARNESSES` table of
`shellforged/models.py`, which also derives the routes above) because their
real `Stop` would otherwise race the guess. A real transition that arrives
first always wins and cancels the pending settle.

Every hook post is telemetry: it is acknowledged with `{}` before the daemon
handles it, and no response ever carries a hook decision. The exceptions are
Harness Test's probes (`_aiterm_daemon_test_id`, `_aiterm_test_id`), which the
receiver answers itself by echoing their id and never hands on, so neither can
change state on any route.

Every request must carry `X-AiTerm-Hook: 1`; requests without it get a plain
404, the same as an unknown route, so the receiver never reveals that these
routes exist to a caller that doesn't know the header (any other local
process, or a browser page via a CORS-simple POST). The tab a Codex, Grok or PI
post came from travels in `X-AiTerm-iTerm-Session`; a body field of the same
name is discarded. A `Content-Length` that is not a plain decimal is a 400,
and one over 1 MiB a 413. A head of more than 100 header lines or 32 KiB is a
431, answered before the header check. A request with `Expect: 100-continue` gets an interim
`100 Continue` before the daemon reads the body, so `curl` doesn't wait out
its own 1s timeout past the shim's 300 ms cap.

## Development

`ruff check shellforged` and `mypy` (configured in `pyproject.toml`: strict, except
for `shellforged.iterm_bridge`, which wraps the untyped iterm2 library, and the
tests) run from the dev extras alongside the tests.
