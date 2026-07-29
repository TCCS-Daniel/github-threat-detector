from typing import Any

from collectors.github_client import paginate
from db.queries import upsert_github_events_batch


def _collect_path(path: str, source: str) -> int:
    total = 0
    for page in paginate(path):
        for event in page:
            event["_source"] = source
        total += upsert_github_events_batch(page)
    return total


def collect_repo_events(owner: str, repo: str) -> int:
    return _collect_path(f"/repos/{owner}/{repo}/events", "events_api")


def collect_org_events(org: str) -> int:
    return _collect_path(f"/orgs/{org}/events", "events_api")


def collect_user_events(username: str) -> int:
    return _collect_path(f"/users/{username}/events/public", "events_api")


def collect_for_repo(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)
    return collect_repo_events(owner, repo)


def collect_for_org(org: str) -> int:
    return collect_org_events(org)
