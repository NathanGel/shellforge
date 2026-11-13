# shellforged

Shellforge's daemon: it receives the agents' hooks and status lines, keeps each tab's status, model,
context and token counts, and tracks usage. It was copied from AiTerm's daemon (see `NOTICE.md`).

    python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'   # once
    .venv/bin/python -m shellforged run                          # sessions from the app
    .venv/bin/python -m shellforged ctl sessions.list            # ask a running daemon
    .venv/bin/pytest -q                                          # tests

It keeps its socket (`shellforged.sock`), `daemon.json`, log and `hook-port` in
`~/Library/Application Support/Shellforge/`, and listens for hooks on `127.0.0.1:47831`, so it runs
beside AiTerm's daemon on one Mac.

`--support-dir <folder>` (on `run` and `ctl`) puts its files in another folder; the socket defaults
to `shellforged.sock` in it. Without the option it uses `$SHELLFORGE_SUPPORT` (an absolute path, as
the app sets it and the shims read it), then the folder above.
A dev build passes its own data folder and its own `--hook-port`, so its helper runs beside the
installed app's:

    .venv/bin/python -m shellforged run --support-dir ~/Library/Application\ Support/example-dev --hook-port 48123

**Where sessions come from.** By default the app sends its tabs with `sessions.update` — each tab's
session guid, window, tab index, command line, job pid, title, folder and task — and the daemon
needs nothing beyond the standard library. `--session-source iterm` reads them from iTerm2's Python
API instead, through `iterm_bridge.py`, which needs the `iterm2` package; live tests against a
running iTerm2: `SHELLFORGED_LIVE=1 .venv/bin/pytest tests/integration -q`.

## App connection

The app starts the daemon with `--app-pid <its own pid>`. Only a connection from that process, by
the peer pid the kernel gives for the socket (`LOCAL_PEERPID`), may call the app's methods: every
method but `agents.takeLaunch`, which `shellforge-run` calls from the agent's tab and which checks
its caller's terminal itself. Any other process of the same user gets `unauthorized`, or
`unknown_method` for `workspace.snapshot`, which an app from before this check reads as a helper
of another version. The daemon quits as soon as that process exits (a kqueue `NOTE_EXIT`), so no
later process can be handed the trusted pid and a relaunch starts a fresh daemon rather than
adopting this one. Run by hand without `--app-pid`, as with `ctl`, every connection is the app's.

`workspace.snapshot` returns protocol version 2, iTerm2 availability, tagged sessions, and
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

**Agent launches.** For an agent that isn't built in, or one with an environment of its own, the
app arms the launch with the helper over the socket (`agents.armLaunch`): the environment, secrets included, for one
tab and one agent, single-use, held in memory for at most 60 seconds and never logged.
`shellforge-run` in that tab takes it (`agents.takeLaunch`, `run_agent.py`) and execs the agent,
so no value is typed, shown in scrollback or kept in shell history.

## Hook receiver

The daemon listens on `127.0.0.1:<hookPort>` (default 47831) for eight POST
routes, used by the installed Claude Code / Codex / Grok Build command hooks,
the PI extension, the two statusline shims and `shellforge-status`:

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
- `POST /status` — `shellforge-status working|needs-input|done`, the exact
  status any other agent's own hooks report (`hook_events.STATUS_ROUTE`).

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
Harness Test's probes (`_shellforge_daemon_test_id`, `_shellforge_test_id`), which the
receiver answers itself by echoing their id and never hands on, so neither can
change state on any route.

Every request must name the receiver as its `Host`: `127.0.0.1:<port>` or
`localhost:<port>`, as every installed hook's URL does. Any other `Host`, or none,
is a 421 with no body, answered before the body is read: a DNS-rebinding page
reaches 127.0.0.1 under its own name, which its browser sends, and it can send the
marker header below.

Every request must carry `X-Shellforge-Hook: 1`; requests without it get a plain
404, the same as an unknown route, so the receiver never reveals that these
routes exist to a caller that doesn't know the header (any other local
process, or a browser page via a CORS-simple POST). The tab a Codex, Grok, PI or
`shellforge-status` post came from travels in `X-Shellforge-iTerm-Session`; a body field of the same
name is discarded. A `Content-Length` that is not a plain decimal is a 400,
and one over 1 MiB a 413. A head of more than 100 header lines or 32 KiB is a
431, answered before the header check. A request with `Expect: 100-continue` gets an interim
`100 Continue` before the daemon reads the body, so `curl` doesn't wait out
its own 1s timeout past the shim's 300 ms cap.

## Development

`ruff check shellforged` and `mypy` (configured in `pyproject.toml`: strict, except
for `shellforged.iterm_bridge`, which wraps the untyped iterm2 library, and the
tests) run from the dev extras alongside the tests.
