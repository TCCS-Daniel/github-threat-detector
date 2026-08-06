from __future__ import annotations

import logging
import os
import threading
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger("api.run")

# Optional collectors (matching the CLI flags) the run job may execute;
# enabled with the RUN_COLLECTORS env var, e.g.
# RUN_COLLECTORS=commits,tags,activities
COLLECTOR_FLAGS = (
    "actions",
    "contributors",
    "workflow-files",
    "commits",
    "scan-parents",
    "git-inspect",
    "tags",
    "activities",
    "snapshots",
    "author-search",
)

# One job at a time; state is kept in-process and exposed via /api/run/status.
_LOCK = threading.Lock()
_STATE: dict[str, Any] = {
    "status": "idle",  # idle | running | done | error
    "step": None,  # collect | analyze
    "detail": None,
    "started_at": None,
    "finished_at": None,
    "error": None,
    "result": None,
}


def _update(**changes: Any) -> None:
    with _LOCK:
        _STATE.update(changes)


def get_status() -> dict[str, Any]:
    with _LOCK:
        return dict(_STATE)


def _enabled_collectors() -> set[str]:
    raw = os.environ.get("RUN_COLLECTORS", "")
    names = {n.strip().lower() for n in raw.split(",") if n.strip()}
    return names & set(COLLECTOR_FLAGS)


def _collect() -> dict[str, int]:
    from config import DEFAULT_ORGS, DEFAULT_REPOS, TARGET_REPO_PREFIX
    from collectors.actions import collect_workflow_runs
    from collectors.activities import collect_repo_activities
    from collectors.author_search import collect_author_search
    from collectors.commits import collect_push_commits
    from collectors.contributors import collect_contributors
    from collectors.events import collect_for_org, collect_for_repo
    from collectors.git_repo import clone_and_inspect
    from collectors.repos import resolve_target_repos
    from collectors.snapshots import collect_org_members, collect_repo_snapshots
    from collectors.tags import collect_repo_tags
    from collectors.workflow_files import collect_workflow_files

    enabled = _enabled_collectors()
    prefix = (TARGET_REPO_PREFIX or "").strip() or None
    repos = resolve_target_repos(DEFAULT_REPOS, DEFAULT_ORGS, prefix)
    if not repos and not DEFAULT_ORGS:
        raise RuntimeError(
            "No repos or orgs configured. Set GITHUB_REPOS or GITHUB_ORGS."
        )

    events = 0
    collect_errors = 0

    # A failing step is skipped (logged and counted), not fatal to the run.
    def step(label: str, fn, *args, **kwargs):
        nonlocal collect_errors
        _update(detail=label)
        try:
            return fn(*args, **kwargs)
        except Exception as exc:
            collect_errors += 1
            logger.warning("collector step failed (%s): %s", label, exc)
            return None

    for full_name in repos:
        events += step(f"events: {full_name}", collect_for_repo, full_name) or 0
        if "actions" in enabled:
            step(f"actions: {full_name}", collect_workflow_runs, full_name)
        if "contributors" in enabled:
            step(f"contributors: {full_name}", collect_contributors, full_name)
        if "workflow-files" in enabled:
            step(f"workflow files: {full_name}", collect_workflow_files, full_name)
        if "commits" in enabled:
            step(
                f"commits: {full_name}",
                collect_push_commits,
                full_name,
                scan_parents="scan-parents" in enabled,
            )
        if "git-inspect" in enabled:
            step(f"git inspect: {full_name}", clone_and_inspect, full_name)
        if "tags" in enabled:
            step(f"tags: {full_name}", collect_repo_tags, full_name)
        if "activities" in enabled:
            step(f"activities: {full_name}", collect_repo_activities, full_name)
        if "snapshots" in enabled:
            step(f"snapshots: {full_name}", collect_repo_snapshots, full_name)

    for org in DEFAULT_ORGS:
        events += step(f"org events: {org}", collect_for_org, org) or 0
        if "snapshots" in enabled:
            step(f"org members: {org}", collect_org_members, org)

    if "author-search" in enabled:
        step("author search", collect_author_search)

    return {"repos": len(repos), "new_events": events, "collect_errors": collect_errors}


def _analyze() -> dict[str, int]:
    from analyzers.detection_queries import ANALYZERS

    findings = 0
    rule_errors = 0
    for analyzer in ANALYZERS:
        _update(detail=f"rule: {analyzer.rule_id}")
        try:
            findings += analyzer.run(repo_name=None)
        except Exception:
            rule_errors += 1
    return {"rules": len(ANALYZERS), "findings": findings, "rule_errors": rule_errors}


def _run() -> None:
    from db.client import apply_schema

    try:
        apply_schema()
        _update(step="collect", detail=None)
        collected = _collect()
        _update(step="analyze", detail=None)
        analyzed = _analyze()
        _update(
            status="done",
            step=None,
            detail=None,
            finished_at=datetime.now(timezone.utc).isoformat(),
            result={**collected, **analyzed},
        )
    except Exception as exc:
        _update(
            status="error",
            step=None,
            detail=None,
            finished_at=datetime.now(timezone.utc).isoformat(),
            error=str(exc),
        )


# Starts a collect + analyze job. Returns False if one is already running.
def start_run() -> bool:
    with _LOCK:
        if _STATE["status"] == "running":
            return False
        _STATE.update(
            status="running",
            step="collect",
            detail=None,
            started_at=datetime.now(timezone.utc).isoformat(),
            finished_at=None,
            error=None,
            result=None,
        )
    threading.Thread(target=_run, name="collect-analyze", daemon=True).start()
    return True
