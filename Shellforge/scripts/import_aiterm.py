#!/usr/bin/env python3
"""Brings an AiTerm setup into Shellforge: its projects in AiTerm's order with their Jira links, its
dividers, terminals and tasks, and the agent and model each project last used.

    Shellforge/scripts/import_aiterm.py [--dry-run]

Run it with Shellforge quit: the app writes workspace.json itself and would write over the import.
A project already in Shellforge (the same folder) keeps its id, SSH host and tunnels; its Jira links
gain AiTerm's. A task whose worktree is gone from disk is left out. The workspace as it was is kept
beside it first, as workspace.json.before-aiterm-<time>. Nothing in AiTerm is changed.

Jira, GitLab and GitHub connections are not here: they are the app's settings and Keychain items.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

AITERM = Path.home() / "Library/Application Support/AiTerm/state.json"
SHELLFORGE = Path.home() / "Library/Application Support/Shellforge/workspace.json"


def merge(aiterm: dict, workspace: dict, *, exists=os.path.exists, model_defaults: dict[str, str] | None = None) -> tuple[dict, list[str]]:
    """The workspace with AiTerm's setup in it, and what was done, line by line."""
    said: list[str] = []
    out = json.loads(json.dumps(workspace))
    by_path = {p["path"]: p for p in out.get("projects", [])}
    ids: dict[str, str] = {}  # AiTerm project id -> Shellforge's
    projects: list[dict] = []
    dividers: list[dict] = []
    for item in aiterm.get("items", []):
        if item.get("kind") == "divider":
            d = item["divider"]
            dividers.append({"id": d["id"], "name": d.get("name", ""), "position": len(projects)})
        elif item.get("kind") == "project":
            p = item["project"]
            mine = by_path.pop(p["path"], None)
            if mine is not None:
                known = {(j["key"], j.get("siteURL")) for j in mine.get("jiraProjects", [])}
                added = [j for j in p.get("jiraProjects", []) if (j["key"], j.get("siteURL")) not in known]
                mine["jiraProjects"] = mine.get("jiraProjects", []) + added
                ids[p["id"]] = mine["id"]
                projects.append(mine)
                said.append(f"kept {mine['name']}" + (f", +{len(added)} Jira" if added else ""))
            else:
                project = {"id": p["id"], "name": p["name"], "path": p["path"], "addedAt": p["addedAt"],
                           "collapsed": p.get("collapsed", False), "jiraProjects": p.get("jiraProjects", [])}
                ids[p["id"]] = p["id"]
                projects.append(project)
                said.append(f"added {p['name']}")
    # Shellforge's own projects AiTerm does not have go after AiTerm's.
    projects += [p for p in out.get("projects", []) if p["path"] in by_path]
    out["projects"] = projects
    existing_dividers = {d["id"] for d in out.get("dividers", [])}
    out["dividers"] = out.get("dividers", []) + [d for d in dividers if d["id"] not in existing_dividers]
    said.append(f"{len(dividers)} dividers")

    task_ids = {t["id"] for t in out.get("tasks", [])}
    for t in aiterm.get("tasks", []):
        if t["id"] in task_ids or t.get("projectId") not in ids:
            continue
        if not exists(t["worktreePath"]):
            said.append(f"left out task {t['title']}: its worktree is gone")
            continue
        task = {k: t[k] for k in ("id", "title", "branch", "worktreePath", "baseBranch", "createdAt") if k in t}
        task["projectId"] = ids[t["projectId"]]
        for k in ("agent", "model", "reasoning", "jira", "kind", "mr"):
            if t.get(k) is not None:
                task[k] = t[k]
        out.setdefault("tasks", []).append(task)
        said.append(f"added task {t['title']}")

    terminal_ids = {t["id"] for t in out.get("terminals", [])}
    for t in aiterm.get("terminals", []):
        if t["id"] in terminal_ids or t.get("projectId") not in ids:
            continue
        out.setdefault("terminals", []).append({"id": t["id"], "projectId": ids[t["projectId"]], "name": t["name"], "createdAt": t["createdAt"]})
        said.append(f"added terminal {t['name']}")

    # Swift writes a dictionary keyed by UUID as [key, value, key, value, …].
    last = dict(zip(out.get("lastAgentByProject", [])[::2], out.get("lastAgentByProject", [])[1::2]))
    theirs = aiterm.get("lastAgentByProject", [])
    for project, agent in zip(theirs[::2], theirs[1::2]):
        if project in ids:
            last.setdefault(ids[project], agent)
    out["lastAgentByProject"] = [x for pair in last.items() for x in pair]
    models = dict(out.get("lastModelByAgent", {}))
    theirs = aiterm.get("lastModelByAgent", [])
    for agent, model in list(zip(theirs[::2], theirs[1::2])) + list((model_defaults or {}).items()):
        models.setdefault(agent, model)
    out["lastModelByAgent"] = models
    return out, said


def aiterm_model_defaults() -> dict[str, str]:
    """AiTerm's per-agent default model, from its settings."""
    found = {}
    for agent in ("claude", "codex", "grok", "pi"):
        answer = subprocess.run(["/usr/bin/defaults", "read", "com.laurensdhondt.aiterm", f"modelDefaults.{agent}"],
                                capture_output=True, text=True).stdout
        for line in answer.splitlines():
            line = line.strip()
            if line.startswith("model ="):
                found[agent] = line.split("=", 1)[1].strip().rstrip(";").strip('"')
    return found


def shellforge_running() -> bool:
    """By bundle id: a release runs as Shellforge.app, a source build as iTerm2.app."""
    return subprocess.run(["/usr/bin/osascript", "-e", 'application id "io.github.nathangel.shellforge" is running'],
                          capture_output=True, text=True).stdout.strip() == "true"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="say what would change, change nothing")
    args = parser.parse_args()
    if not AITERM.exists():
        print(f"No AiTerm setup at {AITERM}.", file=sys.stderr)
        return 1
    workspace = json.loads(SHELLFORGE.read_text()) if SHELLFORGE.exists() else {"version": 1, "projects": [], "tasks": []}
    merged, said = merge(json.loads(AITERM.read_text()), workspace, model_defaults=aiterm_model_defaults())
    print("\n".join(said))
    if args.dry_run:
        return 0
    if shellforge_running():
        print("Quit Shellforge first: it would write over the import.", file=sys.stderr)
        return 1
    SHELLFORGE.parent.mkdir(parents=True, exist_ok=True)
    if SHELLFORGE.exists():
        backup = SHELLFORGE.with_name(f"workspace.json.before-aiterm-{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(SHELLFORGE, backup)
        print(f"kept the workspace as it was in {backup.name}")
    temporary = SHELLFORGE.with_suffix(".json.importing")
    temporary.write_text(json.dumps(merged, indent=2, sort_keys=True))
    os.replace(temporary, SHELLFORGE)
    print(f"wrote {SHELLFORGE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
