from typing import Any


def _event_type_from_header(header_value: str) -> str:
    parts = [p for p in header_value.split("_") if p]
    return "".join(p.capitalize() for p in parts) + "Event"


def _source_from_target_type(target_type: str | None) -> str:
    if target_type == "organization":
        return "webhook_org"
    if target_type == "repository":
        return "webhook_repo"
    return "webhook"


def to_github_event_row(headers: dict[str, str], body: dict[str, Any]) -> dict[str, Any]:
    delivery_id = headers.get("x-github-delivery")
    event_header = headers.get("x-github-event")
    if not delivery_id or not event_header:
        raise ValueError("missing X-GitHub-Delivery or X-GitHub-Event header")

    event_type = _event_type_from_header(event_header)

    sender = body.get("sender") or {}
    repo = body.get("repository") or {}
    org = body.get("organization") or {}

    payload = dict(body)
    if event_type == "PushEvent" and "after" in payload and "head" not in payload:
        payload["head"] = payload["after"]

    repo_name = repo.get("full_name")
    org_login = org.get("login")
    if not repo_name and org_login:
        repo_name = f"{org_login}/_org_"

    return {
        "id": delivery_id,
        "event_type": event_type,
        "actor_login": sender.get("login"),
        "actor_id": sender.get("id"),
        "repo_name": repo_name,
        "org_login": org_login,
        "payload": payload,
        "source": _source_from_target_type(headers.get("x-github-hook-installation-target-type")),
        "notes": None,
    }
