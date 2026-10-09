import json
import os
from datetime import datetime
from types import SimpleNamespace

import pytest

from shellforged.codex_sessions import LIST_SECONDS, CodexSessionFiles
from shellforged.models import TokenTally


def write_rollout(root, session_id, records, day="2026/09/22"):
    path = root / day / f"rollout-2026-09-22T09-26-25-{session_id}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(record) if isinstance(record, dict) else record for record in records) + "\n")
    return path


def token_count(total_tokens, context_window):
    return {
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {
                "last_token_usage": {"total_tokens": total_tokens},
                "model_context_window": context_window,
            },
        },
    }


def meta(thread_id, *, session_id=None, parent=None, spawned_by=None):
    payload = {"id": thread_id, "session_id": session_id or thread_id}
    if parent:
        payload["parent_thread_id"] = parent
    if spawned_by:
        payload["source"] = {"subagent": {"thread_spawn": {"parent_thread_id": spawned_by, "depth": 1}}}
    return {"type": "session_meta", "payload": payload}


def totals(input_tokens, cached, output):
    return {"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {
        "input_tokens": input_tokens, "cached_input_tokens": cached, "cache_write_input_tokens": 0,
        "output_tokens": output, "total_tokens": input_tokens + output}}}}


def test_reads_latest_valid_context_for_the_exact_codex_session(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "other-thread", [token_count(99, 100)])
    write_rollout(root, "thread-1", [
        token_count(10, 100),
        token_count(42_600, 100_000),
        "{unfinished",
    ])

    assert CodexSessionFiles(root).context_percent("thread-1") == 43


def test_rejects_unusable_codex_context_numbers_and_clamps_overflow(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "zero-window", [token_count(42, 0)])
    write_rollout(root, "boolean", [token_count(True, 100)])
    write_rollout(root, "overflow", [token_count(140, 100)])

    files = CodexSessionFiles(root)
    assert files.context_percent("missing") is None
    assert files.context_percent("zero-window") is None
    assert files.context_percent("boolean") is None
    assert files.context_percent("overflow") == 100


def rate_limited(primary, secondary=None, plan="team", timestamp="2026-09-22T14:31:09.229Z"):
    """A `token_count` record the way Codex writes it: the rate limits ride along with the tokens."""
    record = token_count(100, 1000)
    record["timestamp"] = timestamp
    record["payload"]["rate_limits"] = {"limit_id": "codex", "primary": primary, "secondary": secondary, "plan_type": plan}
    return record


def test_rate_limits_come_from_the_newest_record_of_the_newest_rollout(tmp_path):
    # Account-wide, so whichever session wrote last is the truth -- not the one Shellforge happens to
    # track. The record's own timestamp is the age of the number, not when we read it.
    root = tmp_path / "sessions"
    older = write_rollout(root, "older", [rate_limited({"used_percent": 10.0, "window_minutes": 10080, "resets_at": 1},
                                                       timestamp="2026-09-22T10:00:00.000Z")])
    newer = write_rollout(root, "newer", [
        rate_limited({"used_percent": 20.0, "window_minutes": 10080, "resets_at": 2}, timestamp="2026-09-22T12:00:00.000Z"),
        token_count(5, 1000),  # a later token_count without rate limits does not erase them
        rate_limited({"used_percent": 52.0, "window_minutes": 10080, "resets_at": 1790582049}, timestamp="2026-09-22T14:31:09.229Z"),
        "{unfinished",
    ])
    import os
    os.utime(older, ns=(1, 1))
    os.utime(newer, ns=(2, 2))

    limits, at = CodexSessionFiles(root).rate_limits()
    assert limits["primary"] == {"used_percent": 52.0, "window_minutes": 10080, "resets_at": 1790582049}
    assert limits["plan_type"] == "team"
    assert at == 1790087469  # 2026-09-22T14:31:09Z


def test_rate_limits_are_none_without_a_usable_record(tmp_path):
    root = tmp_path / "sessions"
    assert CodexSessionFiles(root).rate_limits() is None  # no sessions dir at all
    write_rollout(root, "tokens-only", [token_count(1, 10)])
    write_rollout(root, "not-a-dict", [{"type": "event_msg", "timestamp": "2026-09-22T14:31:09Z",
                                        "payload": {"type": "token_count", "rate_limits": ["nope"]}}])
    assert CodexSessionFiles(root).rate_limits() is None


def test_rate_limits_without_a_timestamp_still_count_and_age_as_unknown(tmp_path):
    root = tmp_path / "sessions"
    record = rate_limited({"used_percent": 3.0, "window_minutes": 300, "resets_at": None})
    del record["timestamp"]
    write_rollout(root, "t", [record])
    limits, at = CodexSessionFiles(root).rate_limits()
    assert limits["primary"]["used_percent"] == 3.0 and at is None


def test_rate_limits_are_not_reread_until_a_rollout_changes(tmp_path, monkeypatch):
    # The tick asks every two seconds; a rollout nobody has written to is not read again.
    root = tmp_path / "sessions"
    path = write_rollout(root, "t", [rate_limited({"used_percent": 52.0, "window_minutes": 10080, "resets_at": 1})])
    files = CodexSessionFiles(root)
    reads = []
    real = CodexSessionFiles._lines_reverse
    monkeypatch.setattr(CodexSessionFiles, "_lines_reverse", staticmethod(lambda p, *a: reads.append(p) or real(p, *a)))

    first = files.rate_limits()
    assert files.rate_limits() == first and reads == [path]

    import os
    with path.open("a") as stream:
        stream.write(json.dumps(rate_limited({"used_percent": 53.0, "window_minutes": 10080, "resets_at": 1})) + "\n")
    os.utime(path, ns=(path.stat().st_mtime_ns + 1, path.stat().st_mtime_ns + 1))
    limits, _ = files.rate_limits()
    assert limits["primary"]["used_percent"] == 53.0 and reads == [path, path]


def test_rejects_non_finite_codex_context_numbers(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "inf-window", [token_count(42, float("inf"))])
    write_rollout(root, "nan-total", [token_count(float("nan"), 100)])
    files = CodexSessionFiles(root)
    assert files.context_percent("inf-window") is None
    assert files.context_percent("nan-total") is None


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def limits(percent):
    return rate_limited({"used_percent": percent, "window_minutes": 10080, "resets_at": 1})


def test_the_tree_is_relisted_at_most_every_list_interval(tmp_path):
    root, clock = tmp_path / "sessions", Clock()
    first = write_rollout(root, "first", [limits(10.0)])
    os.utime(first, ns=(1, 1))
    files = CodexSessionFiles(root, clock=clock)
    assert files.rate_limits()[0]["primary"]["used_percent"] == 10.0

    # A newer rollout in an old day's directory waits for the next full listing...
    old_day = write_rollout(root, "old-day", [limits(20.0)], day="2001/01/01")
    os.utime(old_day, ns=(2, 2))
    assert files.rate_limits()[0]["primary"]["used_percent"] == 10.0
    clock.now += LIST_SECONDS
    assert files.rate_limits()[0]["primary"]["used_percent"] == 20.0

    # ...while one written under today's date, where a new Codex session writes, is seen at once.
    today = write_rollout(root, "today", [limits(30.0)], day=datetime.now().strftime("%Y/%m/%d"))
    os.utime(today, ns=(3, 3))
    assert files.rate_limits()[0]["primary"]["used_percent"] == 30.0


def test_context_is_not_reparsed_until_its_rollout_changes(tmp_path, monkeypatch):
    root = tmp_path / "sessions"
    path = write_rollout(root, "t", [token_count(10, 100)])
    files = CodexSessionFiles(root)
    reads = []
    real = CodexSessionFiles._lines_reverse
    monkeypatch.setattr(CodexSessionFiles, "_lines_reverse", staticmethod(lambda p, *a: reads.append(p) or real(p, *a)))

    assert files.context_percent("t") == 10
    assert files.context_percent("t") == 10 and reads == [path]
    with path.open("a") as stream:
        stream.write(json.dumps(token_count(20, 100)) + "\n")
    assert files.context_percent("t") == 20 and reads == [path, path]


def test_a_thread_without_a_rollout_is_not_searched_for_across_the_tree_every_tick(tmp_path):
    root, clock = tmp_path / "sessions", Clock()
    files = CodexSessionFiles(root, clock=clock)
    write_rollout(root, "other", [token_count(1, 100)])
    assert files.context_percent("late") is None

    write_rollout(root, "late", [token_count(40, 100)], day="2001/01/01")
    assert files.context_percent("late") is None
    clock.now += LIST_SECONDS
    assert files.context_percent("late") == 40

    # A brand-new thread's rollout appears under today's date and is found without waiting.
    assert files.context_percent("new") is None
    write_rollout(root, "new", [token_count(7, 100)], day=datetime.now().strftime("%Y/%m/%d"))
    assert files.context_percent("new") == 7


def test_a_rollout_is_scanned_for_token_counts_without_parsing_every_line(tmp_path, monkeypatch):
    """Most of a rollout is messages and tool output, and one with no `token_count` at all is read
    in full on every poll while Codex writes to it: its lines are looked for as bytes, and only a
    candidate is parsed."""
    from shellforged import codex_sessions

    root = tmp_path / "sessions"
    chatter = {"type": "response_item", "payload": {"type": "message", "content": "hello"}}
    write_rollout(root, "thread-1", [token_count(42, 100), *[chatter] * 50])
    parsed = []

    def counting_loads(line, *args, **kwargs):
        parsed.append(line)
        return json.loads(line, *args, **kwargs)

    # The module's own name for json, not the json module every other caller shares.
    monkeypatch.setattr(codex_sessions, "json", SimpleNamespace(loads=counting_loads))

    assert CodexSessionFiles(root).context_percent("thread-1") == 42
    assert len(parsed) == 1


def test_a_line_that_mentions_token_count_without_being_one_is_still_skipped(tmp_path):
    root = tmp_path / "sessions"
    quoting = {"type": "response_item", "payload": {"type": "message", "content": 'grep "token_count" rollout.jsonl'}}
    write_rollout(root, "thread-1", [token_count(42, 100), quoting])

    assert CodexSessionFiles(root).context_percent("thread-1") == 42


@pytest.mark.parametrize("block_size", [1, 2, 3, 7, 16, 64, 4096])
def test_matching_lines_are_found_whichever_block_they_straddle(tmp_path, block_size):
    lines = [b"plain one", b'{"a": "token_count", "n": 1}', b"", b"x" * 40, b'"token_count"', b"tail", b'{"token_count": 2}']
    for ending in (b"\n", b""):
        path = tmp_path / f"rollout-{block_size}-{len(ending)}.jsonl"
        path.write_bytes(b"\n".join(lines) + ending)

        found = list(CodexSessionFiles._lines_reverse(path, b'"token_count"', block_size))

        assert found == [lines[6], lines[4], lines[1]]


def test_a_threads_tally_is_its_newest_total(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "t1", [meta("t1"), totals(100, 60, 5), totals(3_283_279, 3_093_248, 18_391)])
    assert CodexSessionFiles(root).tally("t1") == TokenTally(3_283_279, 3_093_248, 18_391)


def test_review_spawned_and_nested_children_are_added_and_strangers_are_not(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "t1", [meta("t1"), totals(1_000, 900, 10)])
    write_rollout(root, "review", [meta("review", session_id="t1", parent="t1"), totals(800, 700, 20)])
    write_rollout(root, "spawn", [meta("spawn", session_id="t1", spawned_by="t1"), totals(400, 300, 30)])
    write_rollout(root, "grandchild", [meta("grandchild", parent="spawn"), totals(40, 0, 4)])
    write_rollout(root, "stranger", [meta("stranger"), totals(9_999, 0, 999)])
    assert CodexSessionFiles(root).tally("t1") == TokenTally(2_240, 1_900, 64)


def test_a_child_written_on_a_later_day_is_found(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "t1", [meta("t1"), totals(10, 0, 1)], day="2026/09/22")
    write_rollout(root, "late", [meta("late", parent="t1"), totals(5, 0, 1)], day="2026/09/23")
    assert CodexSessionFiles(root).tally("t1") == TokenTally(15, 0, 2)


def test_a_rollout_without_totals_adds_nothing(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "t1", [meta("t1")])
    assert CodexSessionFiles(root).tally("t1") is None
    write_rollout(root, "child", [meta("child", parent="t1"), totals(5, 1, 1)])
    assert CodexSessionFiles(root).tally("t1") == TokenTally(5, 1, 1)


def test_totals_are_not_reread_until_a_rollout_changes(tmp_path, monkeypatch):
    root, reads = tmp_path / "sessions", []
    write_rollout(root, "t1", [meta("t1"), totals(10, 0, 1)])
    files = CodexSessionFiles(root)
    original = files._read_total
    monkeypatch.setattr(files, "_read_total", lambda path: (reads.append(path), original(path))[1])
    files.tally("t1")
    files.tally("t1")
    assert len(reads) == 1
