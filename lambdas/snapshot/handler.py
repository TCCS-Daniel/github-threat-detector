import logging
import os
from typing import Any

from bootstrap import load_github_token, split_csv

load_github_token()

from collectors.actions import collect_workflow_runs
from collectors.activities import collect_repo_activities
from collectors.commits import collect_push_commits
from collectors.contributors import collect_contributors
from collectors.events import collect_for_repo as collect_events_for_repo
from collectors.snapshots import collect_org_members, collect_repo_snapshots
from collectors.tags import collect_repo_tags
from collectors.workflow_files import collect_workflow_files
from collectors.repos import resolve_target_repos_from_env
from analyzers.detection_queries import SNAPSHOT_ANALYZERS as DETECTION_ANALYZERS

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _run(label: str, fn, *args) -> Any:
    try:
        n = fn(*args)
        logger.info("%s ok target=%s n=%s", label, args, n)
        return n
    except Exception as exc:
        logger.exception("%s failed target=%s", label, args)
        return {"error": str(exc)}


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    repos = resolve_target_repos_from_env()
    orgs = split_csv(os.environ.get("TARGET_ORGS"))
    logger.info("collector start repos=%s orgs=%s", repos, orgs)

    results: dict[str, Any] = {"repos": {}, "orgs": {}}

    for repo in repos:
        results["repos"][repo] = {
            "snapshot": _run("snapshot", collect_repo_snapshots, repo),
            "events": _run("events", collect_events_for_repo, repo),
            "commits": _run("commits", collect_push_commits, repo, True),
            "tags": _run("tags", collect_repo_tags, repo),
            "activities": _run("activities", collect_repo_activities, repo),
            "workflow_runs": _run("workflow_runs", collect_workflow_runs, repo),
            "workflow_files": _run("workflow_files", collect_workflow_files, repo),
            "contributors": _run("contributors", collect_contributors, repo),
        }

    for org in orgs:
        results["orgs"][org] = {
            "members": _run("org_members", collect_org_members, org),
        }

    results["findings"] = {
        analyzer.rule_id: _run(analyzer.rule_id, analyzer.run)
        for analyzer in DETECTION_ANALYZERS
    }

    return results
