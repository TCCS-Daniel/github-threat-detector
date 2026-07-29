import hashlib
import json
from datetime import datetime, timezone
from typing import Any, Callable

from collectors.github_client import paginate
from db.queries import get_git_repo_check, upsert_git_repo_check, upsert_github_event


def _list_paginated(path: str, wrapper_key: str | None = None, params: dict | None = None) -> list[dict]:
    items: list[dict] = []
    for page in paginate(path, params):
        if isinstance(page, list):
            items.extend(page)
        elif wrapper_key:
            items.extend(page.get(wrapper_key, []))
    return items


def _emit_drift_events(
    repo_name: str,
    resource: str,
    event_prefix: str,
    prev_items: list[dict],
    curr_items: list[dict],
    key_fn: Callable[[dict], str],
    name_fn: Callable[[dict], str],
    content_fn: Callable[[dict], dict],
) -> int:
    prev_map = {key_fn(i): i for i in prev_items}
    curr_map = {key_fn(i): i for i in curr_items}
    org = repo_name.split("/", 1)[0]
    now_iso = datetime.now(timezone.utc).isoformat()
    emitted = 0

    for k in curr_map.keys() - prev_map.keys():
        _emit(repo_name, org, resource, event_prefix, "Added", k,
              name_fn(curr_map[k]), curr_map[k], None, now_iso)
        emitted += 1
    for k in prev_map.keys() - curr_map.keys():
        _emit(repo_name, org, resource, event_prefix, "Removed", k,
              name_fn(prev_map[k]), None, prev_map[k], now_iso)
        emitted += 1
    for k in prev_map.keys() & curr_map.keys():
        if content_fn(prev_map[k]) == content_fn(curr_map[k]):
            continue
        _emit(repo_name, org, resource, event_prefix, "Modified", k,
              name_fn(curr_map[k]), curr_map[k], prev_map[k], now_iso)
        emitted += 1
    return emitted


def _emit(
    repo_name: str,
    org: str,
    resource: str,
    prefix: str,
    change: str,
    item_key: str,
    item_name: str,
    curr: dict | None,
    prev: dict | None,
    ts: str,
) -> None:
    id_input = json.dumps(
        {"r": repo_name, "x": resource, "c": change, "k": item_key, "cur": curr, "prv": prev},
        sort_keys=True, default=str,
    )
    event_id = hashlib.sha256(id_input.encode()).hexdigest()
    upsert_github_event({
        "id": event_id,
        "type": f"{prefix}.{change}",
        "actor": {},
        "repo": {"name": repo_name},
        "org": {"login": org},
        "payload": {
            "resource": resource,
            "change": change,
            "item_key": item_key,
            "item_name": item_name,
            "current": curr,
            "previous": prev,
        },
        "created_at": ts,
        "_source": "snapshot",
    })


def _run_snapshot(
    repo_name: str,
    check_type: str,
    items: list[dict],
    event_prefix: str,
    key_fn: Callable[[dict], str],
    name_fn: Callable[[dict], str],
    content_fn: Callable[[dict], dict],
) -> int:
    prev = get_git_repo_check(repo_name, check_type) or {}
    prev_items = prev.get("items", [])
    upsert_git_repo_check(repo_name, check_type, {"items": items})
    return _emit_drift_events(
        repo_name, check_type, event_prefix,
        prev_items, items, key_fn, name_fn, content_fn,
    )


def collect_repo_hooks(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)
    items = _list_paginated(f"/repos/{owner}/{repo}/hooks")
    return _run_snapshot(
        full_name, "hooks", items, "Hook",
        key_fn=lambda h: str(h.get("id")),
        name_fn=lambda h: (h.get("config") or {}).get("url") or str(h.get("id")),
        content_fn=lambda h: {
            "events": sorted(h.get("events") or []),
            "active": h.get("active"),
            "config": h.get("config") or {},
        },
    )


def collect_repo_branches(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)
    items = _list_paginated(f"/repos/{owner}/{repo}/branches")
    return _run_snapshot(
        full_name, "branches", items, "Branch",
        key_fn=lambda b: b.get("name", ""),
        name_fn=lambda b: b.get("name", ""),
        content_fn=lambda b: {
            "sha": (b.get("commit") or {}).get("sha"),
            "protected": b.get("protected"),
        },
    )


def collect_repo_actions_secrets(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)
    items = _list_paginated(f"/repos/{owner}/{repo}/actions/secrets", wrapper_key="secrets")
    return _run_snapshot(
        full_name, "actions_secrets", items, "Secret",
        key_fn=lambda s: s.get("name", ""),
        name_fn=lambda s: s.get("name", ""),
        content_fn=lambda s: {"updated_at": s.get("updated_at")},
    )


def collect_repo_collaborators(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)
    items = _list_paginated(f"/repos/{owner}/{repo}/collaborators")
    return _run_snapshot(
        full_name, "collaborators", items, "Collaborator",
        key_fn=lambda u: u.get("login", ""),
        name_fn=lambda u: u.get("login", ""),
        content_fn=lambda u: {
            "permissions": u.get("permissions") or {},
            "role_name": u.get("role_name"),
        },
    )


def collect_repo_releases_snapshot(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)
    items = _list_paginated(f"/repos/{owner}/{repo}/releases")
    return _run_snapshot(
        full_name, "releases", items, "Release",
        key_fn=lambda r: str(r.get("id")),
        name_fn=lambda r: r.get("tag_name") or r.get("name") or str(r.get("id")),
        content_fn=lambda r: {
            "tag_name": r.get("tag_name"),
            "target_commitish": r.get("target_commitish"),
            "draft": r.get("draft"),
            "prerelease": r.get("prerelease"),
            "name": r.get("name"),
        },
    )


def collect_repo_workflows_inventory(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)
    items = _list_paginated(f"/repos/{owner}/{repo}/actions/workflows", wrapper_key="workflows")
    return _run_snapshot(
        full_name, "workflows_inventory", items, "Workflow",
        key_fn=lambda w: str(w.get("id")),
        name_fn=lambda w: w.get("path") or w.get("name") or str(w.get("id")),
        content_fn=lambda w: {
            "state": w.get("state"),
            "path": w.get("path"),
            "name": w.get("name"),
        },
    )


def collect_org_members(org: str) -> int:
    items = _list_paginated(f"/orgs/{org}/members")
    repo_name = f"{org}/_org_"
    return _run_snapshot(
        repo_name, "org_members", items, "Member",
        key_fn=lambda u: u.get("login", ""),
        name_fn=lambda u: u.get("login", ""),
        content_fn=lambda u: {"id": u.get("id"), "type": u.get("type")},
    )


def collect_repo_snapshots(full_name: str) -> int:
    total = 0
    total += collect_repo_hooks(full_name)
    total += collect_repo_branches(full_name)
    total += collect_repo_actions_secrets(full_name)
    total += collect_repo_collaborators(full_name)
    total += collect_repo_releases_snapshot(full_name)
    total += collect_repo_workflows_inventory(full_name)
    return total
