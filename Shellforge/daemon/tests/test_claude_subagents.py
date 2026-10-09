import json
import os

import pytest

from shellforged import claude_subagents
from shellforged.claude_subagents import SubagentTranscripts

# The records a Claude subagent transcript ends with, as Claude Code 2.1.285 writes them.
PROMPT = {"type": "user", "isSidechain": True, "agentId": "c1", "message": {"role": "user", "content": "Fix the tests"}}
ASSISTANT = {"type": "assistant", "isSidechain": True, "agentId": "c1",
             "message": {"role": "assistant", "content": [{"type": "text", "text": "Working on it"}]}}
# What the stream watchdog leaves when it kills a stalled child.
INTERRUPTED = {"type": "user", "isSidechain": True, "agentId": "c1",
               "message": {"role": "user", "content": [{"type": "text", "text": "[Request interrupted by user]"}]}}
INTERRUPTED_IN_TOOL = {"type": "user", "isSidechain": True, "agentId": "c1", "message": {"role": "user", "content": [
    {"type": "tool_result", "tool_use_id": "toolu_1", "content": "…"},
    {"type": "text", "text": "[Request interrupted by user for tool use]"}]}}
STOPPED = {"type": "attachment", "isSidechain": True, "agentId": "c1",
           "attachment": {"type": "hook_success", "hookName": "SubagentStop", "hookEvent": "SubagentStop", "exitCode": 200}}
# The same hook when the daemon was not listening.
STOP_FAILED = {"type": "attachment", "attachment": {"type": "hook_non_blocking_error", "hookEvent": "SubagentStop"}}
STARTED = {"type": "attachment", "attachment": {"type": "hook_success", "hookName": "SubagentStart:general-purpose",
                                                "hookEvent": "SubagentStart"}}


def write(path, *records, tail=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in records) + tail)
    return str(path)


@pytest.mark.parametrize("last,ended", [
    (INTERRUPTED, True), (INTERRUPTED_IN_TOOL, True), (STOPPED, True), (STOP_FAILED, True),
    (ASSISTANT, False), (PROMPT, False), (STARTED, False),
    # The watchdog's text inside a tool result or an assistant message is not the interruption.
    ({"type": "assistant", "message": {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}}, False),
])
def test_a_transcript_has_ended_only_on_an_interruption_or_a_subagent_stop(tmp_path, last, ended):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, ASSISTANT, last)
    tail = SubagentTranscripts().read(path)
    assert tail is not None and tail.ended is ended


def test_a_missing_transcript_reads_as_none(tmp_path):
    assert SubagentTranscripts().read(str(tmp_path / "agent-c1.jsonl")) is None


def test_a_record_still_being_written_has_not_ended(tmp_path):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, INTERRUPTED, tail='{"type": "user", "mess')
    assert SubagentTranscripts().read(path).ended is False


def test_only_the_tail_is_read(tmp_path, monkeypatch):
    # A last record longer than the tail window is neither of the small records that end a child.
    monkeypatch.setattr(claude_subagents, "TAIL_BYTES", 256)
    big = {"type": "user", "message": {"content": [{"type": "text", "text": "[Request interrupted by user]"}]}, "pad": "x" * 1000}
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, big)
    assert SubagentTranscripts().read(path).ended is False
    path = write(tmp_path / "agent-c2.jsonl", *([ASSISTANT] * 50), INTERRUPTED)
    assert os.path.getsize(path) > 256
    assert SubagentTranscripts().read(path).ended is True


def test_the_tail_is_stamped_with_the_files_mtime_and_size(tmp_path):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT)
    os.utime(path, ns=(5_000_000_000, 5_000_000_000))
    tail = SubagentTranscripts().read(path)
    assert tail.stamp == (5_000_000_000, os.path.getsize(path))
    assert tail.written_at == 5.0


def test_an_unchanged_transcript_is_not_read_again(tmp_path, monkeypatch):
    path = write(tmp_path / "agent-c1.jsonl", PROMPT, INTERRUPTED)
    transcripts = SubagentTranscripts()
    first = transcripts.read(path)
    monkeypatch.setattr(claude_subagents, "_has_ended", lambda _tail: pytest.fail("reparsed an unchanged file"))
    assert transcripts.read(path) == first


def test_a_transcript_in_a_subdirectory_of_subagents_is_found(tmp_path):
    # Claude Code files some agents under subagents/<subdir>/ (its agentTranscriptSubdirs).
    subagents = tmp_path / "sess" / "subagents"
    write(subagents / "wf-1" / "agent-c1.jsonl", PROMPT, INTERRUPTED)
    assert SubagentTranscripts().read(str(subagents / "agent-c1.jsonl")).ended is True


def test_read_all_answers_only_the_transcripts_that_exist(tmp_path):
    present = write(tmp_path / "agent-c1.jsonl", PROMPT)
    missing = str(tmp_path / "agent-c2.jsonl")
    assert set(SubagentTranscripts().read_all({present, missing})) == {present}
