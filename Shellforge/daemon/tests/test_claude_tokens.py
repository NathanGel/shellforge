import json

from shellforged.claude_tokens import ClaudeTranscriptTallies
from shellforged.models import TokenTally


def reply(message_id, *, fresh=0, written=0, read=0, output=0, model="claude-opus-5"):
    return {"type": "assistant", "message": {"id": message_id, "model": model, "usage": {
        "input_tokens": fresh, "cache_creation_input_tokens": written, "cache_read_input_tokens": read,
        "output_tokens": output}}}


def append(path, *records, newline=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "\n".join(json.dumps(r) if isinstance(r, dict) else r for r in records)
    with path.open("a") as stream:
        stream.write(text + ("\n" if newline else ""))


def subagent(transcript, name):
    return transcript.with_suffix("") / "subagents" / f"agent-{name}.jsonl"


def test_each_reply_counts_once_with_its_last_lines_usage(tmp_path):
    transcript = tmp_path / "s.jsonl"
    # One reply, one line per content block; only the last has the final output count.
    append(transcript, reply("m1", fresh=2, written=1_253, read=63_242, output=21),
           reply("m1", fresh=2, written=1_253, read=63_242, output=1_070),
           {"type": "user", "message": {"content": "next"}},
           reply("m2", fresh=3, read=64_000, output=5))
    assert ClaudeTranscriptTallies().tally(str(transcript)) == TokenTally(128_500, 128_495, 1_075)


def test_subagents_of_every_kind_are_added_and_a_forks_copied_replies_are_not(tmp_path):
    transcript = tmp_path / "s.jsonl"
    append(transcript, reply("p1", fresh=10, output=1))
    append(subagent(transcript, "background"), reply("b1", fresh=100, read=900, output=50))
    append(subagent(transcript, "nested"), reply("n1", fresh=7, output=3))
    # A fork starts from a copy of its parent's history.
    append(subagent(transcript, "fork"), reply("p1", fresh=10, output=1), reply("f1", fresh=1, output=1))
    # 10 + 1,000 + 7 + 1 in, 900 of it cache; 1 + 50 + 3 + 1 out. The fork's copy of p1 is not added.
    assert ClaudeTranscriptTallies().tally(str(transcript)) == TokenTally(1_018, 900, 55)


def test_a_forks_copy_of_a_replys_partial_line_never_lowers_the_parents_final_count(tmp_path):
    transcript = tmp_path / "s.jsonl"
    append(transcript, reply("m1", fresh=2, read=90, output=21), reply("m1", fresh=2, read=90, output=238))
    # The fork copied only the reply's first content block, and its file is read after the parent's.
    append(subagent(transcript, "fork"), reply("m1", fresh=2, read=90, output=21))
    assert ClaudeTranscriptTallies().tally(str(transcript)) == TokenTally(92, 90, 238)


def test_a_workflows_subagents_one_directory_deeper_are_counted(tmp_path):
    transcript = tmp_path / "s.jsonl"
    append(transcript, reply("p1", fresh=10, output=1))
    # Workflow agents sit under subagents/<workflow>/, not directly in subagents/.
    append(transcript.with_suffix("") / "subagents" / "wf" / "agent-x.jsonl", reply("w1", fresh=20, read=80, output=4))
    assert ClaudeTranscriptTallies().tally(str(transcript)) == TokenTally(110, 80, 5)


def test_only_replies_count_never_a_restated_childs_spend_or_a_synthetic_message(tmp_path):
    transcript = tmp_path / "s.jsonl"
    append(transcript,
           {"type": "user", "toolUseResult": {"totalTokens": 99_999, "usage": {"input_tokens": 99_999}}},
           {"type": "queued_command", "attachment": {"usage": {"totalTokens": 88_888}}},
           reply("x", fresh=0, output=0, model="<synthetic>"),
           reply("m1", fresh=5, output=2), "{unfinished json")
    assert ClaudeTranscriptTallies().tally(str(transcript)) == TokenTally(5, 0, 2)


def test_a_conversation_without_replies_has_no_tally(tmp_path):
    tallies = ClaudeTranscriptTallies()
    assert tallies.tally(str(tmp_path / "missing.jsonl")) is None
    empty = tmp_path / "empty.jsonl"
    append(empty, {"type": "user", "message": {"content": "hi"}})
    assert tallies.tally(str(empty)) is None


def test_a_reply_half_written_is_counted_once_it_is_complete(tmp_path):
    transcript, tallies = tmp_path / "s.jsonl", ClaudeTranscriptTallies()
    line = json.dumps(reply("m1", fresh=4, output=2))
    append(transcript, line[:20], newline=False)
    assert tallies.tally(str(transcript)) is None
    with transcript.open("a") as stream:
        stream.write(line[20:] + "\n")
    assert tallies.tally(str(transcript)) == TokenTally(4, 0, 2)
    assert tallies.tally(str(transcript)) == TokenTally(4, 0, 2)


def test_a_subagent_that_keeps_working_keeps_adding(tmp_path):
    transcript, tallies = tmp_path / "s.jsonl", ClaudeTranscriptTallies()
    append(transcript, reply("p1", fresh=1, output=1))
    child = subagent(transcript, "background")
    append(child, reply("c1", fresh=10, output=10))
    assert tallies.tally(str(transcript)) == TokenTally(11, 0, 11)
    # The parent's turn has ended; the background child has not.
    append(child, reply("c2", fresh=20, output=20))
    assert tallies.tally(str(transcript)) == TokenTally(31, 0, 31)


def test_a_rewritten_transcript_is_read_again_from_the_start(tmp_path):
    transcript, tallies = tmp_path / "s.jsonl", ClaudeTranscriptTallies()
    append(transcript, reply("m1", fresh=50, output=5), reply("m2", fresh=50, output=5))
    assert tallies.tally(str(transcript)) == TokenTally(100, 0, 10)
    transcript.write_text(json.dumps(reply("m9", fresh=1, output=1)) + "\n")
    assert tallies.tally(str(transcript)) == TokenTally(1, 0, 1)


def test_unchanged_files_are_not_read_again(tmp_path, monkeypatch):
    transcript, tallies, reads = tmp_path / "s.jsonl", ClaudeTranscriptTallies(), []
    append(transcript, reply("m1", fresh=1, output=1))
    original = ClaudeTranscriptTallies._read
    monkeypatch.setattr(ClaudeTranscriptTallies, "_read", classmethod(
        lambda cls, *args: (reads.append(args[0]), original.__func__(cls, *args))[1]))
    tallies.tally(str(transcript))
    tallies.tally(str(transcript))
    assert len(reads) == 1


def test_retain_forgets_conversations_no_tab_runs(tmp_path):
    transcript, tallies = tmp_path / "s.jsonl", ClaudeTranscriptTallies()
    append(transcript, reply("m1", fresh=1, output=1))
    tallies.tally(str(transcript))
    tallies.retain(set())
    assert tallies._conversations == {}
