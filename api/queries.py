from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

from config import HIDDEN_ORGS
from db.client import get_cursor
from api.entities import extract_entities, finding_pin_ts

SEVERITY_ORDER = "CASE severity WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3 WHEN 'low' THEN 4 ELSE 5 END"
RELATED_CAP = 20
SINCE_CHOICES = ("15m", "1h", "4h", "1d", "7d")


def parse_since(since_str: str | None) -> datetime | None:
    if not since_str:
        return None
    raw = since_str.strip().lower()
    if raw.endswith("m") and raw[:-1].isdigit():
        return datetime.now(timezone.utc) - timedelta(minutes=int(raw[:-1]))
    if raw.endswith("h") and raw[:-1].isdigit():
        return datetime.now(timezone.utc) - timedelta(hours=int(raw[:-1]))
    if raw.endswith("d") and raw[:-1].isdigit():
        return datetime.now(timezone.utc) - timedelta(days=int(raw[:-1]))
    ts = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts


def _serialize_finding(row: dict[str, Any]) -> dict[str, Any]:
    finding = dict(row)
    if finding.get("created_at") is not None:
        finding["created_at"] = finding["created_at"].isoformat()
    if finding.get("evidence") is None:
        finding["evidence"] = {}
    finding["entities"] = extract_entities(finding)
    return finding


def _exclude_hidden_orgs(conditions: list[str], params: dict[str, Any]) -> None:
    if HIDDEN_ORGS:
        conditions.append("lower(split_part(repo_name, '/', 1)) != ALL(%(hidden_orgs)s)")
        params["hidden_orgs"] = HIDDEN_ORGS


def list_orgs() -> list[str]:
    conditions = ["repo_name LIKE '%%/%%'"]
    params: dict[str, Any] = {}
    _exclude_hidden_orgs(conditions, params)
    sql = f"""
        SELECT DISTINCT split_part(repo_name, '/', 1) AS org
        FROM findings
        WHERE {" AND ".join(conditions)}
        ORDER BY org
    """
    with get_cursor(dict_cursor=True) as cur:
        cur.execute(sql, params)
        return [r["org"] for r in cur.fetchall() if r["org"]]


def list_repos(org: str | None = None) -> list[str]:
    conditions = []
    params: dict[str, Any] = {}
    if org:
        conditions.append("split_part(repo_name, '/', 1) = %(org)s")
        params["org"] = org
    else:
        _exclude_hidden_orgs(conditions, params)
    where = ("WHERE " + " AND ".join(conditions)) if conditions else ""
    sql = f"""
        SELECT DISTINCT repo_name
        FROM findings
        {where}
        ORDER BY repo_name
    """
    with get_cursor(dict_cursor=True) as cur:
        cur.execute(sql, params)
        return [r["repo_name"] for r in cur.fetchall() if r["repo_name"]]


def list_findings(
    org: str | None = None,
    repo: str | None = None,
    severity: list[str] | None = None,
    since: str | None = None,
) -> list[dict[str, Any]]:
    conditions = []
    params: dict[str, Any] = {}
    if org:
        conditions.append("split_part(repo_name, '/', 1) = %(org)s")
        params["org"] = org
    if repo:
        conditions.append("repo_name = %(repo)s")
        params["repo"] = repo
    if not org and not repo:
        # Hidden orgs stay out of the default view but remain reachable
        # by filtering on them explicitly.
        _exclude_hidden_orgs(conditions, params)
    if severity:
        conditions.append("severity = ANY(%(severity)s)")
        params["severity"] = severity
    since_dt = parse_since(since)
    if since_dt is not None:
        conditions.append("created_at >= %(since)s")
        params["since"] = since_dt
    where = ("WHERE " + " AND ".join(conditions)) if conditions else ""
    sql = f"""
        SELECT id, rule_id, severity, repo_name, actor_login, event_id,
               description, evidence, is_candidate, created_at
        FROM findings
        {where}
        ORDER BY {SEVERITY_ORDER}, created_at DESC, id DESC
    """
    with get_cursor(dict_cursor=True) as cur:
        cur.execute(sql, params)
        return [_serialize_finding(dict(r)) for r in cur.fetchall()]


def get_finding(finding_id: int) -> dict[str, Any] | None:
    sql = """
        SELECT id, rule_id, severity, repo_name, actor_login, event_id,
               description, evidence, is_candidate, created_at
        FROM findings
        WHERE id = %(id)s
    """
    with get_cursor(dict_cursor=True) as cur:
        cur.execute(sql, {"id": finding_id})
        row = cur.fetchone()
        if not row:
            return None
        return _serialize_finding(dict(row))


def _peer_rows(
    *,
    exclude_id: int,
    repo_name: str | None = None,
    actor_login: str | None = None,
    tag: str | None = None,
    workflow: str | None = None,
    commit: str | None = None,
    release: str | None = None,
    since: str | None = None,
) -> tuple[int, list[dict[str, Any]]]:
    conditions = ["id <> %(exclude_id)s"]
    params: dict[str, Any] = {"exclude_id": exclude_id, "cap": RELATED_CAP}

    since_dt = parse_since(since)
    if since_dt is not None:
        conditions.append("created_at >= %(since)s")
        params["since"] = since_dt

    if repo_name is not None:
        conditions.append("repo_name = %(repo_name)s")
        params["repo_name"] = repo_name
    if actor_login is not None:
        conditions.append("actor_login = %(actor_login)s")
        params["actor_login"] = actor_login
    if tag is not None:
        conditions.append(
            "("
            "evidence->>'tag_name' = %(tag)s OR "
            "regexp_replace(COALESCE(evidence->>'tag', ''), '^refs/tags/', '') = %(tag)s"
            ")"
        )
        params["tag"] = tag
    if workflow is not None:
        conditions.append(
            "("
            "evidence->>'workflow_path' = %(workflow)s OR "
            "evidence->>'path' = %(workflow)s OR "
            "evidence->>'workflow_name' = %(workflow)s"
            ")"
        )
        params["workflow"] = workflow
    if commit is not None:
        conditions.append(
            "("
            "lower(evidence->>'sha') = %(commit)s OR "
            "lower(evidence->>'commit_sha') = %(commit)s OR "
            "lower(evidence->>'legit_sha') = %(commit)s OR "
            "lower(evidence->>'poisoned_sha') = %(commit)s OR "
            "lower(evidence->>'after') = %(commit)s OR "
            "left(lower(COALESCE(evidence->>'sha', '')), length(%(commit)s)) = %(commit)s OR "
            "left(lower(COALESCE(evidence->>'commit_sha', '')), length(%(commit)s)) = %(commit)s"
            ")"
        )
        params["commit"] = commit.lower()
    if release is not None:
        conditions.append(
            "("
            "evidence->>'release_id' = %(release)s OR "
            "evidence->>'tag_name' = %(release)s OR "
            "regexp_replace(COALESCE(evidence->>'tag', ''), '^refs/tags/', '') = %(release)s"
            ")"
        )
        params["release"] = release

    where = " AND ".join(conditions)
    count_sql = f"SELECT count(*) AS n FROM findings WHERE {where}"
    list_sql = f"""
        SELECT id, rule_id, severity, repo_name, actor_login, event_id,
               description, evidence, is_candidate, created_at
        FROM findings
        WHERE {where}
        ORDER BY {SEVERITY_ORDER}, created_at DESC, id DESC
        LIMIT %(cap)s
    """
    with get_cursor(dict_cursor=True) as cur:
        cur.execute(count_sql, params)
        total = int(cur.fetchone()["n"])
        cur.execute(list_sql, params)
        rows = [_serialize_finding(dict(r)) for r in cur.fetchall()]
    return total, rows


def related_findings(
    finding_id: int,
    since: str | None = None,
    repo: str | None = None,
) -> dict[str, Any] | None:
    finding = get_finding(finding_id)
    if finding is None:
        return None

    entities = finding["entities"]
    facets: dict[str, Any] = {}

    for key in ("commit", "release", "tag", "user", "workflow", "repo"):
        value = entities.get(key)
        if not value:
            facets[key] = {"value": None, "status": "absent", "total": 0, "findings": []}
            continue
        kwargs: dict[str, Any] = {"exclude_id": finding_id, "since": since}
        if key == "repo":
            kwargs["repo_name"] = value
        elif key == "user":
            kwargs["actor_login"] = value
        elif key == "tag":
            kwargs["tag"] = value
        elif key == "workflow":
            kwargs["workflow"] = value
        elif key == "commit":
            kwargs["commit"] = value
        else:
            kwargs["release"] = value
        if repo and key != "repo":
            kwargs["repo_name"] = repo
        total, rows = _peer_rows(**kwargs)
        facets[key] = {
            "value": value,
            "status": "ok" if total > 0 else "empty",
            "total": total,
            "findings": rows,
        }
    return {
        "finding_id": finding_id,
        "entities": entities,
        "facets": facets,
    }


def _parse_center(center: str | None) -> datetime:
    if center:
        ts = datetime.fromisoformat(center.replace("Z", "+00:00"))
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        return ts
    return datetime.now(timezone.utc)


def _event_summary(row: dict[str, Any]) -> str:
    kind = row.get("kind") or "event"
    actor = row.get("actor") or ""
    ref = row.get("ref") or ""
    sha = row.get("sha") or ""
    parts = [kind]
    if actor:
        parts.append(f"by {actor}")
    if ref:
        parts.append(ref)
    if sha:
        parts.append(str(sha)[:12])
    return " ".join(parts)


def _serialize_event(row: dict[str, Any]) -> dict[str, Any]:
    ts = row.get("ts")
    return {
        "ts": ts.isoformat() if hasattr(ts, "isoformat") else ts,
        "source": row.get("source"),
        "kind": row.get("kind"),
        "repo_name": row.get("repo_name"),
        "actor": row.get("actor"),
        "ref": row.get("ref"),
        "sha": row.get("sha"),
        "summary": _event_summary(row),
        "pin": None,
    }


def repo_timeline(
    repo: str,
    center: str | None = None,
    window_days: int = 7,
) -> dict[str, Any]:
    center_ts = _parse_center(center)
    delta = timedelta(days=max(1, window_days))
    start = center_ts - delta
    end = center_ts + delta
    sql = """
        SELECT source, repo_name, ts, kind, ref, sha, actor
        FROM v_audit_events
        WHERE repo_name = %(repo)s
          AND ts >= %(start)s
          AND ts <= %(end)s
        ORDER BY ts DESC
        LIMIT 500
    """
    with get_cursor(dict_cursor=True) as cur:
        cur.execute(sql, {"repo": repo, "start": start, "end": end})
        events = [_serialize_event(dict(r)) for r in cur.fetchall()]
    return {
        "mode": "repo",
        "repos": [repo],
        "center": center_ts.isoformat(),
        "window_days": window_days,
        "start": start.isoformat(),
        "end": end.isoformat(),
        "events": events,
        "pins": [],
    }


def compound_timeline(
    f1_id: int,
    f2_id: int,
    window_days: int = 7,
) -> dict[str, Any] | None:
    f1 = get_finding(f1_id)
    f2 = get_finding(f2_id)
    if f1 is None or f2 is None:
        return None

    pin_times = []
    pins = []
    for finding in (f1, f2):
        raw = finding_pin_ts(finding)
        if isinstance(raw, str):
            ts = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        else:
            ts = raw
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        pin_times.append(ts)
        pins.append(
            {
                "finding_id": finding["id"],
                "rule_id": finding["rule_id"],
                "severity": finding["severity"],
                "repo_name": finding["repo_name"],
                "ts": ts.isoformat(),
            }
        )

    center_ts = min(pin_times) + (max(pin_times) - min(pin_times)) / 2
    delta = timedelta(days=max(1, window_days))
    start = min(pin_times) - delta
    end = max(pin_times) + delta
    repos = sorted({f1["repo_name"], f2["repo_name"]})

    sql = """
        SELECT source, repo_name, ts, kind, ref, sha, actor
        FROM v_audit_events
        WHERE repo_name = ANY(%(repos)s)
          AND ts >= %(start)s
          AND ts <= %(end)s
        ORDER BY ts DESC
        LIMIT 800
    """
    with get_cursor(dict_cursor=True) as cur:
        cur.execute(sql, {"repos": repos, "start": start, "end": end})
        events = [_serialize_event(dict(r)) for r in cur.fetchall()]

    for pin in pins:
        events.append(
            {
                "ts": pin["ts"],
                "source": "finding",
                "kind": f"Finding.{pin['rule_id']}",
                "repo_name": pin["repo_name"],
                "actor": None,
                "ref": None,
                "sha": None,
                "summary": f"{pin['severity']} {pin['rule_id']}",
                "pin": {
                    "finding_id": pin["finding_id"],
                    "rule_id": pin["rule_id"],
                    "severity": pin["severity"],
                },
            }
        )
    events.sort(key=lambda e: e["ts"] or "", reverse=True)

    return {
        "mode": "compound",
        "repos": repos,
        "center": center_ts.isoformat(),
        "window_days": window_days,
        "start": start.isoformat(),
        "end": end.isoformat(),
        "events": events,
        "pins": pins,
        "f1": f1_id,
        "f2": f2_id,
    }
