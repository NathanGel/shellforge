# daemon/tests/test_tunnels.py
"""The tunnel supervisor: `ssh -N <alias>` per started tunnel, with the environment the app hands
in, its state broadcast, a drop restarted with backoff, and every tunnel ended with the daemon.
`ssh` here is a script on a temporary PATH; nothing reaches the network."""
import asyncio
import json
import os
import stat
import textwrap

import pytest

from shellforged.tunnels import TunnelSupervisor
from tests.conftest import wait_until
from tests.test_service import call, next_event

FAKE_SSH = textwrap.dedent("""\
    #!/bin/sh
    printf '%s\\n' "$*" > "$FAKE_SSH_LOG.args"
    printf '%s\\n' "$FAKE_SSH_MARK" > "$FAKE_SSH_LOG.env"
    case "$FAKE_SSH_MODE" in
      fail) echo "${FAKE_SSH_LINE:-bind [127.0.0.1]:5432: Address already in use}" >&2; exit 255 ;;
      slow-bind) sleep 0.5; echo "bind [127.0.0.1]:5432: Address already in use" >&2; exit 255 ;;
      ignore-term) trap '' TERM; while :; do sleep 0.05; done ;;
      drop-after:*) sleep "${FAKE_SSH_MODE#drop-after:}"; echo "Connection to bastion closed by remote host." >&2; exit 255 ;;
      *) sleep 600 & wait $! ;;
    esac
    """)


@pytest.fixture
def ssh_env(tmp_path):
    """An environment whose PATH finds the fake ssh, as the app would hand in its own."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    ssh = bin_dir / "ssh"
    ssh.write_text(FAKE_SSH)
    ssh.chmod(ssh.stat().st_mode | stat.S_IEXEC)
    log = tmp_path / "ssh"

    def env(mode="stay", **extra):
        return {"PATH": f"{bin_dir}:/usr/bin:/bin", "FAKE_SSH_MODE": mode, "FAKE_SSH_LOG": str(log),
                "FAKE_SSH_MARK": "handed-in", **extra}

    env.log = log
    yield env
    # A test that failed before stopping its tunnels leaves their fake ssh running: none outlives it.
    kill_fake_ssh(bin_dir)


def kill_fake_ssh(bin_dir) -> int:
    """Every process still running the fake ssh in `bin_dir`, killed with its group. How many."""
    import signal
    import subprocess
    found = subprocess.run(["/usr/bin/pgrep", "-f", str(bin_dir)], capture_output=True, text=True).stdout.split()
    for pid in map(int, found):
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    return len(found)


class Events:
    """Every tunnel.changed broadcast, in order."""

    def __init__(self):
        self.seen: list[dict] = []

    async def broadcast(self, name, payload):
        assert name == "tunnel.changed"
        self.seen.append(payload)

    def states(self, alias):
        return [e["state"] for e in self.seen if e["alias"] == alias]


def fast(events, **overrides):
    return TunnelSupervisor(events.broadcast, **{"up_after": 0.2, "backoff_start": 0.1, "backoff_cap": 0.4, **overrides})


async def test_a_tunnel_comes_up_and_is_broadcast(ssh_env):
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: "up" in events.states("db"))
    assert events.states("db")[:2] == ["connecting", "up"]
    assert tunnels.list() == [{"alias": "db", "state": "up", "error": None, "since": pytest.approx(tunnels.list()[0]["since"]),
                               "bytesIn": None, "bytesOut": None, "heldBy": None, "needsInput": None}]
    await tunnels.stop_all()
    assert events.states("db")[-1] == "stopped"


async def test_a_tunnel_that_fails_at_once_is_failed_not_restarted(ssh_env):
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env("fail"))
    await wait_until(lambda: "failed" in events.states("db"))
    await asyncio.sleep(0.6)
    assert events.states("db") == ["connecting", "failed"], "a failure before it was up is not a drop"
    assert tunnels.list()[0]["error"] == "bind [127.0.0.1]:5432: Address already in use"
    await tunnels.stop_all()


async def test_a_dropped_tunnel_restarts_with_backoff(ssh_env):
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env("drop-after:0.4"))
    await wait_until(lambda: events.states("db").count("up") >= 2, timeout=5)
    states = events.states("db")
    first_up = states.index("up")
    assert "connecting" in states[first_up:], "a drop after being up goes back to connecting"
    assert "failed" not in states
    await tunnels.stop_all()


async def test_stop_during_backoff_stops_for_good(ssh_env):
    events = Events()
    tunnels = fast(events, backoff_start=1.0, backoff_cap=1.0)
    await tunnels.start("db", ssh_env("drop-after:0.3"))
    await wait_until(lambda: events.states("db")[-1:] == ["connecting"] and "up" in events.states("db"), timeout=5)
    await tunnels.stop("db")
    count = len(events.seen)
    await asyncio.sleep(1.5)
    assert events.states("db")[-1] == "stopped"
    assert len(events.seen) == count, "no restart after the stop"


async def test_starting_a_running_tunnel_does_nothing(ssh_env):
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: "up" in events.states("db"))
    pid = tunnels.pid("db")
    await tunnels.start("db", ssh_env())
    assert tunnels.pid("db") == pid
    assert events.states("db") == ["connecting", "up"]
    await tunnels.stop_all()


async def test_two_starts_at_once_run_one_ssh(ssh_env):
    """Two windows auto-starting the same tunnel: the second start comes before the first's run
    has said "connecting", and must not start a second ssh beside it."""
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env())
    first = tunnels._tunnels["db"]
    await tunnels.start("db", ssh_env())
    assert tunnels._tunnels["db"] is first
    await wait_until(lambda: "up" in events.states("db"))
    assert events.states("db") == ["connecting", "up"]
    await tunnels.stop_all()


async def test_the_ssh_arguments_and_environment_are_the_tunnels_own(ssh_env):
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db-staging", ssh_env())
    await wait_until(lambda: os.path.exists(str(ssh_env.log) + ".args"))
    args = open(str(ssh_env.log) + ".args").read().split()
    assert args == ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
                    "-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none", "db-staging"]
    assert open(str(ssh_env.log) + ".env").read().strip() == "handed-in"
    await tunnels.stop_all()


async def test_stopping_ends_the_ssh_process(ssh_env):
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: "up" in events.states("db"))
    pid = tunnels.pid("db")
    await tunnels.stop_all()
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)


async def test_an_ssh_that_is_not_found_fails_with_why(ssh_env):
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", {"PATH": "/nonexistent"})
    await wait_until(lambda: "failed" in events.states("db"))
    assert "ssh" in tunnels.list()[0]["error"]


# -- through the daemon -----------------------------------------------------------------


@pytest.fixture
async def tunnel_stack(make_service):
    svc = make_service()
    svc.tunnels.up_after, svc.tunnels.backoff_start, svc.tunnels.backoff_cap = 0.2, 0.1, 0.4
    await svc.start()
    r, w = await asyncio.open_unix_connection(svc.rpc.path)
    yield svc, r, w
    w.close()


async def test_tunnels_start_broadcasts_and_lists(tunnel_stack, ssh_env):
    svc, r, w = tunnel_stack
    reply = await call(r, w, "tunnels.start", {"alias": "db", "environment": ssh_env()})
    assert reply["result"] == {"ok": True}
    up = None
    while up is None or up["state"] != "up":
        up = await next_event(r, "tunnel.changed")
    assert up["alias"] == "db"
    listed = await call(r, w, "tunnels.list", {}, id_=2)
    assert [t["state"] for t in listed["result"]] == ["up"]
    snapshot = await call(r, w, "workspace.snapshot", {}, id_=3)
    assert [t["alias"] for t in snapshot["result"]["tunnels"]] == ["db"]
    assert (await call(r, w, "tunnels.stop", {"alias": "db"}, id_=4))["result"] == {"ok": True}


async def test_stopping_the_daemon_ends_every_tunnel(make_service, ssh_env):
    svc = make_service()
    svc.tunnels.up_after = 0.2
    await svc.start()
    await svc.tunnels.start("db", ssh_env())
    await wait_until(lambda: svc.tunnels.list()[0]["state"] == "up")
    pid = svc.tunnels.pid("db")
    await svc.stop()
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)


@pytest.mark.parametrize("method,params", [
    ("tunnels.start", {}),
    ("tunnels.start", {"alias": "db"}),
    ("tunnels.start", {"alias": "db", "environment": "PATH=/bin"}),
    ("tunnels.start", {"alias": "db", "environment": {"PATH": 3}}),
    ("tunnels.start", {"alias": "", "environment": {}}),
    ("tunnels.start", {"alias": "-oProxyCommand=evil", "environment": {}}),
    ("tunnels.start", {"alias": "db", "environment": {}, "keepRunning": "yes"}),
    ("tunnels.stop", {}),
])
async def test_malformed_tunnel_params_are_bad_params(tunnel_stack, method, params):
    svc, r, w = tunnel_stack
    assert (await call(r, w, method, params))["error"]["code"] == "bad_params"


async def test_a_fatal_error_after_up_is_failed_not_a_drop(ssh_env):
    """A slow bastion: ssh binds its forwards only after authenticating, past `up_after`. A taken
    port then is still a failure, not a drop to restart forever."""
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env("slow-bind"))
    await wait_until(lambda: "failed" in events.states("db"), timeout=3)
    await asyncio.sleep(0.6)
    assert events.states("db") == ["connecting", "up", "failed"]
    assert tunnels.list()[0]["error"] == "bind [127.0.0.1]:5432: Address already in use"
    await tunnels.stop_all()


async def test_stop_all_ends_every_tunnel_within_one_budget(ssh_env):
    """The app kills the daemon two seconds after asking it to stop: every ssh is signalled at
    once, and the stubborn ones killed together, well inside that."""
    events = Events()
    tunnels = fast(events)
    for alias in ("a", "b", "c"):
        await tunnels.start(alias, ssh_env("ignore-term"))
    await wait_until(lambda: all("up" in events.states(a) for a in ("a", "b", "c")))
    pids = [tunnels.pid(a) for a in ("a", "b", "c")]
    started = asyncio.get_running_loop().time()
    await tunnels.stop_all()
    assert asyncio.get_running_loop().time() - started < 1.6
    for pid in pids:
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)


async def test_no_tunnel_starts_once_stopping_all_began(ssh_env):
    """A start that reaches the daemon while it shuts down would run an ssh nothing ever stops."""
    events = Events()
    tunnels = fast(events)
    await tunnels.stop_all()
    await tunnels.start("db", ssh_env())
    await asyncio.sleep(0.3)
    assert tunnels.list() == [] and tunnels.pid("db") is None


async def test_a_start_right_after_a_failure_starts_again(ssh_env):
    """The user clicks Start as the failure arrives, before its run has quite ended: the click
    is not swallowed."""
    tunnels: TunnelSupervisor
    seen: list[str] = []
    retried = False

    async def broadcast(name, payload):
        nonlocal retried
        seen.append(payload["state"])
        if payload["state"] == "failed" and not retried:
            retried = True
            await tunnels.start("db", ssh_env())

    tunnels = TunnelSupervisor(broadcast, up_after=0.2, backoff_start=0.1, backoff_cap=0.4)
    await tunnels.start("db", ssh_env("fail"))
    await wait_until(lambda: "up" in seen, timeout=3)
    assert seen[:2] == ["connecting", "failed"]
    await tunnels.stop_all()


async def test_keep_running_is_taken_with_the_start(tunnel_stack, ssh_env):
    svc, r, w = tunnel_stack
    reply = await call(r, w, "tunnels.start", {"alias": "db", "environment": ssh_env(), "keepRunning": True})
    assert reply["result"] == {"ok": True}
    assert svc.tunnels._tunnels["db"].keep_running is True
    await svc.tunnels.stop("db")


async def test_a_stop_followed_by_a_start_ends_connecting(ssh_env):
    """A start that lands while a stop is still ending the last ssh: the stop's late "stopped" must
    not be the last word about the new run."""
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env("ignore-term"))
    await wait_until(lambda: "up" in events.states("db"))
    stopping = asyncio.ensure_future(tunnels.stop("db"))
    await asyncio.sleep(0.05)
    await tunnels.start("db", ssh_env())
    await stopping
    await wait_until(lambda: tunnels.list()[0]["state"] == "up", timeout=5)
    assert events.states("db")[-1] == "up", events.states("db")
    await tunnels.stop_all()


async def test_a_missing_key_needs_no_tab(ssh_env):
    """Permission denied (publickey) alone: no answer typed in a tab can help without a key."""
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env("fail", FAKE_SSH_LINE="db: Permission denied (publickey)."))
    await wait_until(lambda: "failed" in events.states("db"))
    assert tunnels.list()[0]["needsInput"] is None
    await tunnels.start("web", ssh_env("fail", FAKE_SSH_LINE="web: Permission denied (publickey,keyboard-interactive)."))
    await wait_until(lambda: "failed" in events.states("web"))
    assert tunnels.list()[1]["needsInput"] is True
    await tunnels.stop_all()


# -- M5b: wakeups --


async def test_an_exit_is_seen_without_polling(ssh_env, monkeypatch):
    """An up tunnel's ssh is waited on, not polled: no Popen.poll for half a second of steady state."""
    import subprocess
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: "up" in events.states("db"))
    polls = []
    real = subprocess.Popen.poll
    monkeypatch.setattr(subprocess.Popen, "poll", lambda self: (polls.append(1), real(self))[1])
    await asyncio.sleep(0.5)
    assert len(polls) <= 2, f"{len(polls)} polls in 0.5 s"
    monkeypatch.setattr(subprocess.Popen, "poll", real)
    await tunnels.stop_all()


async def test_a_drop_is_still_seen_and_restarted(ssh_env):
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env("drop-after:0.4"))
    await wait_until(lambda: events.states("db").count("up") >= 1 and events.states("db")[-1] == "connecting", timeout=5)
    await tunnels.stop_all()


async def test_stop_while_waiting_leaves_no_child(ssh_env):
    import threading
    events = Events()
    tunnels = fast(events)
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: "up" in events.states("db"))
    pid = tunnels.pid("db")
    await tunnels.stop("db")
    with pytest.raises(ProcessLookupError):
        os.kill(pid, 0)
    await wait_until(lambda: not any(t.name == "shellforged-offload" and t.is_alive() for t in threading.enumerate()))


async def test_the_sampler_stops_with_the_last_up_tunnel(ssh_env):
    samples = []

    async def sample(pids):
        samples.append(pids)
        return {}

    events = Events()
    tunnels = fast(events, traffic_every=0.05, sample=sample)
    await tunnels.start("db", ssh_env())
    await wait_until(lambda: samples)
    await tunnels.stop("db")
    await wait_until(lambda: tunnels._sampler is None or tunnels._sampler.done())
    await tunnels.start("db", ssh_env())
    before = len(samples)
    await wait_until(lambda: len(samples) > before, timeout=5)
    await tunnels.stop_all()


def test_no_fake_ssh_outlives_its_test(tmp_path):
    """The fixture's cleanup kills a fake ssh a failed test left running, group and all."""
    import subprocess
    import time
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    ssh = bin_dir / "ssh"
    ssh.write_text(FAKE_SSH)
    ssh.chmod(ssh.stat().st_mode | stat.S_IEXEC)
    child = subprocess.Popen([str(ssh), "db"], env={"PATH": "/usr/bin:/bin", "FAKE_SSH_LOG": str(tmp_path / "log")},
                             start_new_session=True)
    time.sleep(0.2)
    assert kill_fake_ssh(bin_dir) >= 1
    assert child.wait(timeout=2) is not None
