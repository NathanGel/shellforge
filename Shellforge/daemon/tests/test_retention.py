"""What the helper keeps does not grow with time (PRD goal 7): a tab's conversations, the Codex
rollouts it has ever read, and a failure repeated every tick."""
import logging

from shellforged.claude_sessions import ClaudeSessionFiles
from shellforged.codex_sessions import CodexSessionFiles
from shellforged.log_repeats import RepeatFilter
from shellforged.models import RawSession
from shellforged.resolver import SessionResolver
from shellforged.sessions import SessionRegistry
from tests.test_codex_sessions import meta, totals, write_rollout


def test_a_tabs_pins_do_not_grow_with_its_conversations(tmp_path):
    reg = SessionRegistry()
    reg.apply_snapshot([RawSession("a", "w1", 0, "claude", 101, "", "/repo", {})])
    resolver = SessionResolver(reg, ClaudeSessionFiles(tmp_path))
    for i in range(1000):  # every /clear starts a new conversation in the same tab
        resolver.bind("a", "claude", f"conv-{i}")
    assert len(resolver._pins) == 1
    assert resolver.resolve("claude", "conv-999", "/elsewhere") == "a"


def test_rollouts_no_thread_runs_are_forgotten(tmp_path):
    root = tmp_path / "sessions"
    write_rollout(root, "t1", [meta("t1"), totals(10, 0, 1)])
    write_rollout(root, "c1", [meta("c1", parent="t1"), totals(5, 0, 1)])
    write_rollout(root, "other", [meta("other"), totals(1, 0, 1)])
    files = CodexSessionFiles(root)
    assert files.tally("t1") is not None
    assert files._lineage, "the family was read"
    files.retain(set())
    assert files._lineage == {}


def test_a_repeated_failure_is_logged_once_a_while(caplog):
    now = [0.0]
    logger = logging.getLogger("shellforged.test_repeats")
    logger.addFilter(RepeatFilter(every=300, clock=lambda: now[0]))
    with caplog.at_level(logging.WARNING, logger="shellforged.test_repeats"):
        for _ in range(1000):  # every 2 s tick, for a while
            logger.warning("%s took over %.0f s", "codex", 5.0)
            now[0] += 2
        logger.warning("something else")
    messages = [r.getMessage() for r in caplog.records]
    assert messages.count("codex took over 5 s") <= 8
    assert any("repeated" in m for m in messages), "how many were held back is said"
    assert "something else" in messages
