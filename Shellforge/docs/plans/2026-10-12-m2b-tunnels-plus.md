# M2b Tunnels, the rest of the requirements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** M2a's tunnels meet the rest of the PRD's tunnel requirements:
- **Keep running.** A tunnel marked "Keep running" outlives a quit. The next launch adopts it and shows it up, so a relaunch reports every tunnel honestly. An ssh a crashed daemon left behind is found and ended, unless it was meant to keep running.
- **Traffic and uptime.** A running tunnel's row shows how long it has been up, and the bytes in and out.
- **Answer in a tab.** A tunnel that failed because ssh needed input opens in a terminal tab, so the user can answer. Once it is up there, the row shows it as held by that tab. When the tab's ssh ends, the tunnel goes back to supervision.
- **Port holder.** The row's ports say which tunnel holds them, so an `ssh <alias>` in a tab that warns it cannot bind them is not read as a failure.

The command palette and the per-project SSH split pane from New Task are M2c.

**Architecture:**
- **Daemon:**
  - A JSON ledger in the support folder, `tunnels.json`, of every ssh the supervisor runs: alias, pid, start time, keep-running.
  - At start: adopt live keep-running entries; end every other live entry whose command line is still the supervisor's `ssh -N … <alias>`.
  - A traffic sampler runs `/usr/bin/nettop` every 5 s for the up tunnels' pids.
  - A tab-held tunnel is watched by probing its first local port.
- **Swift:**
  - `TunnelDefinition.keepRunning`.
  - `TunnelInfo` gains `bytesIn`, `bytesOut`, `heldBy`.
  - `tunnels.start` carries `keepRunning`.
  - A new `tunnels.hold` method.
  - The row and the sheet show the rest.

**Tech Stack:** Swift 6 language mode, macOS 13, SwiftUI; Swift Testing via `Shellforge/scripts/swift.sh`; Python 3 asyncio daemon with pytest.

**Spec:** Shellforge PRD (Claude Doc 89fd80a8-5fcf-4423-a8d6-c62f8512a481), "Requirements: SSH tunnels":
- "When `ssh` needs input (a host key prompt, a 2FA code), open the tunnel in a terminal tab so the user can answer, then hand it back to supervision."
- "Show bytes in and out, and uptime, per tunnel."
- "Quitting the app stops every tunnel it started, unless the user chose "keep running" for that tunnel."
- "Recover. Quit and relaunch: … running tunnels are reported honestly as stopped or restarted."
- "Interactive sessions. … The sidebar names which tunnel holds a port, so the warning is not mistaken for a failure."

## Global Constraints

- Everything from M2a's Global Constraints holds:
  - `~/.ssh/config` is only read.
  - The supervised `ssh` options are unchanged.
  - Tests use a fake `ssh` (and now a fake `nettop`) on a temporary `PATH`, and read neither the real home nor the network.
  - Protocol `VERSION = 1`: fields and a method are only added, and old clients ignore them.
  - macOS 13; design tokens only.
  - Commits by path, ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; never push.
- **Ending a process found in the ledger:** only when its command line (`ps -o command= -p <pid>`) still is `ssh -N … <alias>` with the supervisor's options. A pid reused by another program is never signalled.
- **The ledger:** written atomically (temp file and rename) and readable by the user. It holds no environment and no secrets: alias, pid, start time, keep-running only.
- **`nettop`:** `/usr/bin/nettop -P -L 1 -x -J bytes_in,bytes_out -p <pid>…`, parsed as CSV, with a 3 s timeout. A missing or failing `nettop` leaves bytes as null; it is never fatal.
- **The tab's ssh:** `ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ControlMaster=no -o ControlPath=none <alias>`, without `BatchMode`. The alias is passed through `AgentCommand.shellWord`.

## Review Focus

1. **A pid in the ledger now belongs to another program** (a reboot, then the pid was reused). Expected: it is not signalled and not adopted, and the entry is dropped. Test: Task 2 `aReusedPidIsLeftAlone`.
2. **The ledger is missing, empty, corrupt or from an older shape.** Expected: the daemon starts with no adopted tunnels and rewrites it. Test: Task 2 `aCorruptLedgerIsIgnored`.
3. **Keep-running tunnel, then the daemon crashes or is killed.** Expected: the next daemon adopts it as up, and Stop ends it. Test: Task 2 `aKeptTunnelIsAdoptedAndCanBeStopped`.
4. **`nettop` hangs, is missing, or prints something unexpected.** Expected: bytes stay null, the sampler keeps running, and the tunnel's state never changes because of it. Test: Task 3 `aBrokenNettopLeavesBytesUnknown`.
5. **The tab is closed while the tunnel is held by it.** Expected: the port closes, the row leaves "held by tab", and the supervisor starts it once in batch mode. If that fails, the row is failed again and offers the tab again. Test: Task 4 `aHeldTunnelIsHandedBackWhenItsPortCloses`.

---

### Task 1: The wire — keep-running, traffic and holder fields

**Files:**
- Modify: `Shellforge/Sources/ShellforgeCore/Tunnels/TunnelDefinition.swift`: `keepRunning: Bool = false`, decoded `?? false`.
- Modify: `Shellforge/Sources/ShellforgeCore/Daemon/DaemonTypes.swift`: `TunnelInfo` gains `bytesIn: Int?`, `bytesOut: Int?`, `heldBy: TunnelHolder?` (`.tab`), all optional in decoding.
- Modify: `DaemonProtocol.swift`: `tunnelsHold`.
- Modify: `DaemonClient.swift`: `startTunnel(alias:environment:keepRunning:)` and `holdTunnel(alias:port:)`.
- Modify: `daemon/shellforged/service.py`:
  - `tunnels.start` takes an optional bool `keepRunning`.
  - `tunnels.hold` takes an `alias` and an int `port` (1 to 65535).
  - Both are validated.
- Modify: `daemon/shellforged/protocol.py`.
- Regenerate the wire fixtures.
- Tests: `TunnelDefinitionTests` (decoding an old project), `DaemonClientTests` (start sends keepRunning; hold sends alias and port), `WireContractTests`, and daemon `test_malformed_tunnel_params_are_bad_params` cases.

- [ ] Tests; run; expected failures.
- [ ] Implement; run the package and the daemon suite; pass.
- [ ] Commit: "Tunnels carry keep-running, traffic and who holds them on the wire".

### Task 2: The ledger — keep running, adopt, reap

**Files:**
- Modify: `daemon/shellforged/tunnels.py`:
  - `TunnelSupervisor(…, ledger: Path | None = None, ps=…)`. `ps` is injectable and returns a pid's command line or None.
  - `start(alias, environment, keep_running=False)`.
  - Each spawn and each end writes the ledger.
  - `stop_all()` leaves keep-running tunnels running and in the ledger.
  - `async adopt()` runs at service start:
    - for each entry whose pid is alive and whose command line matches: keep-running → adopted as `up` with the original `since`; otherwise ended (process group TERM, then KILL);
    - every other entry is dropped.
  - An adopted tunnel has no `asyncio` process: `stop` ends it by pid. A watcher polls its pid each second, and its exit is treated as a drop, restarted with the environment of the last `start` if one was sent. Without one it is `stopped`, with the error "Ended outside Shellforge."
- Modify: `service.py`: `Service(…, tunnel_ledger=None)`; `start()` awaits `tunnels.adopt()`; `__main__` passes `support_dir() / "tunnels.json"`.
- Test: `daemon/tests/test_tunnel_ledger.py`:
  - `keepRunningSurvivesStopAll`
  - `aKeptTunnelIsAdoptedAndCanBeStopped`
  - `aLeftoverTunnelIsEndedAtStart`
  - `aReusedPidIsLeftAlone` (`ps` says `vim`)
  - `aCorruptLedgerIsIgnored`
  - `theLedgerHoldsNoEnvironment`

- [ ] Tests; run; fail.
- [ ] Implement; daemon suite passes.
- [ ] Commit: "A tunnel can keep running past a quit; the next daemon adopts it, and ends ssh a crash left behind".

### Task 3: Traffic

**Files:**
- Create: `daemon/shellforged/traffic.py`:
  - `async sample(pids, run=…) -> dict[int, tuple[int, int]]` parses `nettop`'s CSV (`ssh.<pid>,<in>,<out>,`).
  - The runner is injectable, and has a 3 s timeout.
- Modify: `tunnels.py`:
  - A sampler task runs every `traffic_every` (5 s) while any tunnel is up.
  - It sets `bytes_in` / `bytes_out` and broadcasts `tunnel.changed` only when they changed.
  - A restart resets them to null.
- Test: `daemon/tests/test_traffic.py`:
  - `parsesNettopRows`
  - `aBrokenNettopLeavesBytesUnknown` (missing binary, garbage output, timeout)
  - `upTunnelsGetTheirBytes`

- [ ] Tests; run; fail.
- [ ] Implement; pass.
- [ ] Commit: "A running tunnel reports its bytes in and out".

### Task 4: Answer in a tab, then back to supervision

**Files:**
- Modify: `tunnels.py`:
  - `NEEDS_INPUT = ("Host key verification failed", "Permission denied", "passphrase", "verification code", "keyboard-interactive")`.
  - A failed tunnel whose line holds one of these gets `needsInput: true` in its JSON.
  - `hold(alias, port)`:
    - the supervised run is stopped if one is going;
    - the state is `connecting` with `heldBy: "tab"`;
    - the port is probed each second (connect to 127.0.0.1) and the state is `up` while it accepts;
    - once it stopped accepting after having been up, or never accepted within 120 s, the hold ends and `start` runs once with the last environment. If there is none, it is `stopped`.
- Modify: `TunnelInfo.needsInput: Bool?`.
- Modify: `SidebarModel+Tunnels.swift`: `answerInTab(_ alias:)`:
  - opens a tab through `TerminalHost.openTab` in the first project's folder (a tunnel tab, with no task).
  - Its title is "ssh <alias>" and its command is the tab ssh above.
  - Then it sends `holdTunnel(alias:port:)` with the host's first forward port.
- `TerminalHost` gains `openTab(in:title:command:)` for a tab of no task.
- Tests:
  - daemon `test_tunnel_hold.py`: `aHeldTunnelIsUpWhileItsPortAccepts`, `aHeldTunnelIsHandedBackWhenItsPortCloses`, `aHoldThatNeverComesUpEnds`, `aPromptFailureSaysItNeedsInput`.
  - `TunnelsTests.answeringInATabOpensItAndHolds`.

- [ ] Tests; run; fail.
- [ ] Implement; pass.
- [ ] Commit: "A tunnel that needs an answer opens in a tab, and goes back to supervision when that tab's ssh ends".

### Task 5: The row and the sheet

**Files:**
- Modify: `TunnelRow.swift`:
  - **Up:** a second line in secondary ink: `up 2h 5m · ↓ 1.2 MB ↑ 30 KB`. Uptime comes from `since`, re-drawn each minute by a `TimelineView`. Bytes use `ByteCountFormatter`, and are left out while null.
  - **Held by a tab:** the line is "In a tab", and the button shows the tab rather than stop.
  - **Failed with `needsInput`:** the action is "Answer in Tab" (`terminal`) beside start.
  - **The ports' help:** "Held by <alias>: ssh <alias> in a tab warns it cannot bind <port>, and still connects."
  - **Keep running:** a glyph (`pin.fill`) after the ports, with help "Keeps running after Shellforge quits".
  - `TunnelRowView.look` grows to cover these states.
- Modify: `TunnelsSheet.swift`: a "Keep running after quit" checkbox per linked tunnel.
- Modify: `SidebarModel+Tunnels.swift`: `startTunnel` and the auto-starts send `keepRunning`.
- Tests: `TunnelsTests`:
  - `theRowSaysUptimeAndTraffic`
  - `theRowOffersTheTabWhenSshNeedsInput`
  - `keepRunningIsSentWithTheStart`
  - `theUptimeLineReadsWell` (`0m`, `59m`, `2h 5m`, `3d 4h`)

- [ ] Tests; run; fail.
- [ ] Implement; the package passes, `DesignRulesTests` included.
- [ ] Commit: "Tunnel rows show uptime, traffic, who holds their ports, keep-running and an answer-in-tab action".

### Task 6: Verify in the app

- [ ] Build the app (`** BUILD SUCCEEDED **`); daemon suite and package pass.
- [ ] Live check, for the user:
  1. Set "Keep running" on a tunnel, start it, quit, and relaunch: the row comes back up with the same uptime.
  2. An up row shows its traffic after `curl localhost:<port>`.
  3. Answer in a tab: remove the host's key from `known_hosts` (or use a host that asks for 2FA), start the tunnel, and click "Answer in Tab". Answer, and the row says "In a tab". Close the tab: the row goes back to supervision.
