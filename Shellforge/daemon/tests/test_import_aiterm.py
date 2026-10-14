"""scripts/import_aiterm.py: AiTerm's setup merged into a Shellforge workspace."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("import_aiterm", Path(__file__).parents[2] / "scripts/import_aiterm.py")
importer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(importer)

JIRA = {"id": "1", "key": "ACME", "name": "Acme", "siteURL": "https://example.atlassian.net"}


def aiterm():
    return {
        "items": [
            {"kind": "divider", "divider": {"id": "D1", "name": "Top"}},
            {"kind": "project", "project": {"id": "A1", "name": "web", "path": "/web", "addedAt": "2026-09-01T00:00:00Z", "collapsed": False, "jiraProjects": []}},
            {"kind": "divider", "divider": {"id": "D2", "name": "Mid"}},
            {"kind": "project", "project": {"id": "A2", "name": "api", "path": "/api", "addedAt": "2026-09-01T00:00:00Z", "collapsed": True, "jiraProjects": [JIRA]}},
        ],
        "tasks": [
            {"id": "T1", "projectId": "A2", "title": "Fix", "branch": "fix", "worktreePath": "/api/.worktrees/fix", "baseBranch": "main",
             "createdAt": "2026-10-01T00:00:00Z", "agent": "claude", "model": "opus", "firstPrompt": "x", "windowId": "w", "appendTicket": False},
            {"id": "T2", "projectId": "A1", "title": "Gone", "branch": "g", "worktreePath": "/web/.worktrees/gone", "baseBranch": "main", "createdAt": "2026-10-01T00:00:00Z"},
        ],
        "terminals": [{"id": "X1", "projectId": "A1", "name": "logs", "createdAt": "2026-10-01T00:00:00Z", "windowId": "w"}],
        "lastAgentByProject": ["A1", "codex", "A2", "claude"],
        "lastModelByAgent": ["codex", "gpt"],
    }


def shellforge():
    return {"version": 1, "projects": [{"id": "S2", "name": "api", "path": "/api", "addedAt": "2026-10-14T00:00:00Z", "collapsed": False,
                                         "jiraProjects": [], "sshHost": "api-dev", "tunnels": [{"alias": "db"}]}],
            "tasks": [], "lastAgentByProject": ["S2", "pi"], "lastModelByAgent": {"claude": "opus"}}


def test_projects_take_aiterms_order_and_a_known_folder_keeps_its_own_settings():
    out, _ = importer.merge(aiterm(), shellforge(), exists=lambda p: True)
    assert [p["name"] for p in out["projects"]] == ["web", "api"]
    api = out["projects"][1]
    assert api["id"] == "S2" and api["sshHost"] == "api-dev" and api["tunnels"] == [{"alias": "db"}]
    assert api["jiraProjects"] == [JIRA]


def test_dividers_count_the_projects_above_them():
    out, _ = importer.merge(aiterm(), shellforge(), exists=lambda p: True)
    assert [(d["name"], d["position"]) for d in out["dividers"]] == [("Top", 0), ("Mid", 1)]


def test_tasks_and_terminals_follow_their_project_and_a_gone_worktree_is_left_out():
    out, said = importer.merge(aiterm(), shellforge(), exists=lambda p: p.endswith("fix"))
    assert [(t["id"], t["projectId"]) for t in out["tasks"]] == [("T1", "S2")]
    assert "firstPrompt" not in out["tasks"][0] and "windowId" not in out["tasks"][0]
    assert any("Gone" in line for line in said)
    assert out["terminals"] == [{"id": "X1", "projectId": "A1", "name": "logs", "createdAt": "2026-10-01T00:00:00Z"}]


def test_shellforges_own_choices_win():
    out, _ = importer.merge(aiterm(), shellforge(), exists=lambda p: True, model_defaults={"claude": "sonnet", "grok": "g4"})
    assert dict(zip(out["lastAgentByProject"][::2], out["lastAgentByProject"][1::2])) == {"S2": "pi", "A1": "codex"}
    assert out["lastModelByAgent"] == {"claude": "opus", "codex": "gpt", "grok": "g4"}


def test_a_second_run_adds_nothing():
    once, _ = importer.merge(aiterm(), shellforge(), exists=lambda p: True)
    twice, _ = importer.merge(aiterm(), once, exists=lambda p: True)
    assert twice == once
