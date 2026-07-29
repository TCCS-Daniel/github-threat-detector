from __future__ import annotations

from typing import Any


def _strip_tag(value: str) -> str:
    if value.startswith("refs/tags/"):
        return value[len("refs/tags/") :]
    return value


def _looks_like_workflow(path: str) -> bool:
    lowered = path.lower()
    if ".github/workflows/" in lowered:
        return True
    return lowered.endswith(".yml") or lowered.endswith(".yaml")


def _as_sha(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    raw = value.strip().lower()
    if len(raw) < 7:
        return None
    if all(c in "0123456789abcdef" for c in raw):
        return raw
    return None


def extract_entities(finding: dict[str, Any]) -> dict[str, str | None]:
    repo_name = finding.get("repo_name") or ""
    org = repo_name.split("/", 1)[0] if repo_name else None
    user = finding.get("actor_login") or None

    evidence = finding.get("evidence") or {}
    if not isinstance(evidence, dict):
        evidence = {}

    tag = None
    for key in ("tag_name", "tag", "tag_ref"):
        raw = evidence.get(key)
        if isinstance(raw, str) and raw.strip():
            tag = _strip_tag(raw.strip())
            break
    if tag is None:
        for key in ("tag_list", "tags"):
            raw = evidence.get(key)
            if isinstance(raw, list) and raw:
                first = raw[0]
                if isinstance(first, str) and first.strip():
                    tag = _strip_tag(first.strip())
                    break

    workflow = None
    for key in ("workflow_path", "path"):
        raw = evidence.get(key)
        if isinstance(raw, str) and raw.strip() and _looks_like_workflow(raw.strip()):
            workflow = raw.strip()
            break
    if workflow is None:
        raw = evidence.get("workflow_name")
        if isinstance(raw, str) and raw.strip():
            workflow = raw.strip()

    commit = None
    for key in ("commit_sha", "sha", "legit_sha", "poisoned_sha", "after", "parent_sha"):
        commit = _as_sha(evidence.get(key))
        if commit:
            break

    release = None
    release_id = evidence.get("release_id")
    if release_id is not None and str(release_id).strip():
        release = str(release_id).strip()
    elif finding.get("rule_id", "").startswith("release-") and tag:
        release = tag

    return {
        "org": org or None,
        "repo": repo_name or None,
        "user": user,
        "tag": tag,
        "workflow": workflow,
        "commit": commit,
        "release": release,
    }


def finding_pin_ts(finding: dict[str, Any]):
    evidence = finding.get("evidence") or {}
    if isinstance(evidence, dict):
        for key in ("current_event_at", "created_at", "last_seen", "first_seen"):
            value = evidence.get(key)
            if value:
                return value
    return finding.get("created_at")
