"""Shellforge's daemon must be able to run beside AiTerm's, which it was copied from: its own folder,
socket, port and names."""
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


def test_no_aiterm_name_is_left_in_the_daemon_or_its_shims():
    root = Path(__file__).resolve().parents[1]
    sources = [*(root / "shellforged").glob("*.py"), *(root.parent / "hooks").glob("*")]
    offenders = [p.name for p in sources if p.is_file() and any(word in p.read_text(errors="ignore")
                 for word in ("AiTerm", "aiterm", "AITERM"))]
    assert offenders == []


def test_run_takes_its_sessions_from_the_app_unless_told_otherwise():
    assert main.build_parser().parse_args(["run"]).session_source == "app"
    assert main.build_parser().parse_args(["run", "--session-source", "iterm"]).session_source == "iterm"


def test_the_docs_describe_shellforges_contract_not_aitermds():
    """The README is what a hook installer is written from: a header or port from the daemon this
    was copied from would be silently refused. Only a line naming AiTerm as the origin may stay."""
    root = Path(__file__).resolve().parents[1]
    stale = ("X-AiTerm", "_aiterm", "47821", "aitermd", "Application Support/AiTerm")
    for name in ("README.md", "pyproject.toml"):
        for line in (root / name).read_text().splitlines():
            assert not any(word in line for word in stale), f"{name}: {line}"
