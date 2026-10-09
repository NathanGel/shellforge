"""Shellforge's daemon must be able to run beside Shellforge's: its own folder, socket, port and names."""
from pathlib import Path

from shellforged import __main__ as main
from shellforged import models


def test_run_defaults_are_shellforges_own():
    ns = main.build_parser().parse_args(["run"])
    support = Path.home() / "Library" / "Application Support" / "Shellforge"
    assert ns.socket == str(support / "shellforged.sock")
    assert ns.hook_port == 47831


def test_ctl_talks_to_shellforges_socket():
    ns = main.build_parser().parse_args(["ctl", "sessions.list"])
    assert ns.socket.endswith("/Application Support/Shellforge/shellforged.sock")


def test_session_tags_match_the_swift_package():
    assert (models.TASK_TAG, models.PROJECT_TAG, models.TITLE_TAG) == ("shellforge_task", "shellforge_project", "shellforge_title")
    assert models.ITERM_SESSION_FIELD == "_shellforge_iterm_session_id"


def test_no_shellforge_name_is_left_in_the_daemon_or_its_shims():
    root = Path(__file__).resolve().parents[1]
    sources = [*(root / "shellforged").glob("*.py"), *(root.parent / "hooks").glob("*")]
    offenders = [p.name for p in sources if p.is_file() and any(word in p.read_text(errors="ignore")
                 for word in ("AiTerm", "aiterm", "AITERM"))]
    assert offenders == []
