import json
from datetime import datetime
from typing import Any

from psycopg2.extras import execute_values

from db.client import get_cursor


SOURCE_TO_TABLE = {
    "webhook_org": "events_webhook_org",
    "webhook_repo": "events_webhook_repo",
    "events_api": "events_api",
    "snapshot": "events_snapshot",
}


def _table_for_source(source: str) -> str:
    table = SOURCE_TO_TABLE.get(source)
    if not table:
        raise ValueError(f"Unknown event source: {source}")
    return table


def upsert_github_event(event: dict[str, Any]) -> None:
    source = event.get("_source", "events_api")
    table = _table_for_source(source)
    sql = f"""
        INSERT INTO {table}
            (id, event_type, actor_login, actor_id, repo_name, org_login, payload, created_at)
        VALUES
            (%(id)s, %(event_type)s, %(actor_login)s, %(actor_id)s, %(repo_name)s,
             %(org_login)s, %(payload)s, %(created_at)s)
        ON CONFLICT (id) DO NOTHING
    """
    with get_cursor() as cur:
        cur.execute(sql, {
            "id": event["id"],
            "event_type": event["type"],
            "actor_login": event.get("actor", {}).get("login"),
            "actor_id": event.get("actor", {}).get("id"),
            "repo_name": event.get("repo", {}).get("name"),
            "org_login": event.get("org", {}).get("login"),
            "payload": json.dumps(event.get("payload", {})),
            "created_at": event.get("created_at"),
        })


def upsert_github_events_batch(events: list[dict[str, Any]]) -> int:
    if not events:
        return 0
    by_source: dict[str, list[tuple]] = {}
    for e in events:
        source = e.get("_source", "events_api")
        by_source.setdefault(source, []).append((
            e["id"],
            e["type"],
            e.get("actor", {}).get("login"),
            e.get("actor", {}).get("id"),
            e.get("repo", {}).get("name"),
            e.get("org", {}).get("login"),
            json.dumps(e.get("payload", {})),
            e.get("created_at"),
        ))

    total = 0
    with get_cursor() as cur:
        for source, rows in by_source.items():
            table = _table_for_source(source)
            sql = f"""
                INSERT INTO {table}
                    (id, event_type, actor_login, actor_id, repo_name, org_login, payload, created_at)
                VALUES %s
                ON CONFLICT (id) DO NOTHING
            """
            execute_values(cur, sql, rows)
            total += cur.rowcount
    return total


def upsert_workflow_run(run: dict[str, Any], source: str) -> None:
    sql = """
        INSERT INTO workflow_runs
            (id, repo_name, workflow_name, workflow_path, head_branch, head_sha,
             event, status, conclusion, actor_login, run_started_at, created_at,
             updated_at, payload, source)
        VALUES
            (%(id)s, %(repo_name)s, %(workflow_name)s, %(workflow_path)s,
             %(head_branch)s, %(head_sha)s, %(event)s, %(status)s, %(conclusion)s,
             %(actor_login)s, %(run_started_at)s, %(created_at)s, %(updated_at)s,
             %(payload)s, %(source)s)
        ON CONFLICT (id) DO UPDATE SET
            status = EXCLUDED.status,
            conclusion = EXCLUDED.conclusion,
            updated_at = COALESCE(EXCLUDED.updated_at, now()),
            payload = CASE
                WHEN EXCLUDED.status = 'deleted' THEN workflow_runs.payload
                ELSE EXCLUDED.payload
            END
    """
    with get_cursor() as cur:
        cur.execute(sql, {
            "id": str(run["id"]),
            "repo_name": run.get("repository", {}).get("full_name") or run.get("_repo_name"),
            "workflow_name": run.get("name"),
            "workflow_path": run.get("path"),
            "head_branch": run.get("head_branch"),
            "head_sha": run.get("head_sha"),
            "event": run.get("event"),
            "status": run.get("status"),
            "conclusion": run.get("conclusion"),
            "actor_login": (run.get("triggering_actor") or {}).get("login") or (run.get("actor") or {}).get("login"),
            "run_started_at": run.get("run_started_at"),
            "created_at": run.get("created_at"),
            "updated_at": run.get("updated_at"),
            "payload": json.dumps(run),
            "source": source,
        })


def upsert_push_commit(commit: dict[str, Any]) -> None:
    sql = """
        INSERT INTO push_commits
            (sha, repo_name, push_event_id, author_login, author_email,
             author_name, author_date, committer_login, committer_email,
             committer_name, committer_date, verified, verification_reason,
             parents, files_changed, message_headline, ref, before_sha)
        VALUES
            (%(sha)s, %(repo_name)s, %(push_event_id)s, %(author_login)s, %(author_email)s,
             %(author_name)s, %(author_date)s, %(committer_login)s, %(committer_email)s,
             %(committer_name)s, %(committer_date)s, %(verified)s, %(verification_reason)s,
             %(parents)s, %(files_changed)s, %(message_headline)s, %(ref)s, %(before_sha)s)
        ON CONFLICT (sha, repo_name) DO NOTHING
    """
    with get_cursor() as cur:
        cur.execute(sql, commit)


def upsert_git_repo_check(repo_name: str, check_type: str, result: dict[str, Any]) -> None:
    sql = """
        INSERT INTO git_repo_checks (repo_name, check_type, result)
        VALUES (%(repo_name)s, %(check_type)s, %(result)s)
        ON CONFLICT (repo_name, check_type)
        DO UPDATE SET result = EXCLUDED.result, fetched_at = now()
    """
    with get_cursor() as cur:
        cur.execute(sql, {
            "repo_name": repo_name,
            "check_type": check_type,
            "result": json.dumps(result),
        })


def get_git_repo_check(repo_name: str, check_type: str) -> dict[str, Any] | None:
    sql = """
        SELECT result FROM git_repo_checks
        WHERE repo_name = %(repo_name)s AND check_type = %(check_type)s
    """
    with get_cursor() as cur:
        cur.execute(sql, {"repo_name": repo_name, "check_type": check_type})
        row = cur.fetchone()
    if not row:
        return None
    return row[0]


def upsert_repo_tag(tag: dict[str, Any]) -> str | None:
    check_sql = """
        SELECT tag_sha FROM repo_tags
        WHERE repo_name = %(repo_name)s AND tag_name = %(tag_name)s
    """
    upsert_sql = """
        INSERT INTO repo_tags (repo_name, tag_name, tag_sha, commit_sha, tag_type)
        VALUES (%(repo_name)s, %(tag_name)s, %(tag_sha)s, %(commit_sha)s, %(tag_type)s)
        ON CONFLICT (repo_name, tag_name) DO UPDATE SET
            tag_sha = EXCLUDED.tag_sha,
            commit_sha = EXCLUDED.commit_sha,
            tag_type = EXCLUDED.tag_type,
            fetched_at = now()
    """
    with get_cursor() as cur:
        cur.execute(check_sql, tag)
        row = cur.fetchone()
        old_sha = row[0] if row else None
        cur.execute(upsert_sql, tag)
        if old_sha and old_sha != tag["tag_sha"]:
            return old_sha
    return None


def upsert_repo_activity_batch(activities: list[dict[str, Any]]) -> int:
    if not activities:
        return 0
    rows = [
        (
            str(a["id"]),
            a["_repo_name"],
            a.get("activity_type"),
            (a.get("actor") or {}).get("login"),
            (a.get("actor") or {}).get("id"),
            a.get("ref"),
            a.get("before"),
            a.get("after"),
            a.get("timestamp"),
            json.dumps(a),
            a.get("_source", "api"),
        )
        for a in activities
    ]
    sql = """
        INSERT INTO repo_activities
            (id, repo_name, activity_type, actor_login, actor_id, ref,
             before_sha, after_sha, timestamp, payload, source)
        VALUES %s
        ON CONFLICT (id) DO NOTHING
    """
    with get_cursor() as cur:
        execute_values(cur, sql, rows)
        return cur.rowcount


def upsert_commit_author_search_batch(hits: list[dict[str, Any]]) -> int:
    if not hits:
        return 0
    rows = [
        (
            h["author_email"],
            h["repo_full_name"],
            h["repo_full_name"].split("/")[0],
            h["sha"],
            h.get("author_name"),
            h.get("identity_kind"),
            h.get("source_repo"),
        )
        for h in hits
    ]
    sql = """
        INSERT INTO commit_author_search
            (author_email, repo_full_name, owner, sha, author_name,
             identity_kind, source_repo)
        VALUES %s
        ON CONFLICT (author_email, repo_full_name, sha) DO NOTHING
    """
    with get_cursor() as cur:
        execute_values(cur, sql, rows)
        return cur.rowcount


def insert_tag_drift(repo_name: str, tag_name: str, old_sha: str, new_sha: str) -> None:
    sql = """
        INSERT INTO repo_tags_history (repo_name, tag_name, old_sha, new_sha)
        VALUES (%(repo_name)s, %(tag_name)s, %(old_sha)s, %(new_sha)s)
    """
    with get_cursor() as cur:
        cur.execute(sql, {
            "repo_name": repo_name,
            "tag_name": tag_name,
            "old_sha": old_sha,
            "new_sha": new_sha,
        })


def insert_finding(
    rule_id: str,
    severity: str,
    repo_name: str,
    description: str,
    actor_login: str | None = None,
    event_id: str | None = None,
    evidence: dict[str, Any] | None = None,
    is_candidate: bool = False,
) -> None:
    sql = """
        INSERT INTO findings (rule_id, severity, repo_name, actor_login, event_id, description, evidence, is_candidate)
        VALUES (%(rule_id)s, %(severity)s, %(repo_name)s, %(actor_login)s, %(event_id)s, %(description)s, %(evidence)s, %(is_candidate)s)
        ON CONFLICT DO NOTHING
    """
    with get_cursor() as cur:
        cur.execute(sql, {
            "rule_id": rule_id,
            "severity": severity,
            "repo_name": repo_name,
            "actor_login": actor_login,
            "event_id": event_id,
            "description": description,
            "evidence": json.dumps(evidence) if evidence else None,
            "is_candidate": is_candidate,
        })


def fetch_findings(
    severity: list[str] | None = None,
    repo_name: str | None = None,
    since: datetime | None = None,
) -> list[dict[str, Any]]:
    conditions = []
    params: dict[str, Any] = {}

    if severity:
        conditions.append("severity = ANY(%(severity)s)")
        params["severity"] = severity
    if repo_name:
        conditions.append("repo_name = %(repo_name)s")
        params["repo_name"] = repo_name
    if since:
        conditions.append("created_at >= %(since)s")
        params["since"] = since

    where = ("WHERE " + " AND ".join(conditions)) if conditions else ""
    sql = f"""
        SELECT id, rule_id, severity, repo_name, actor_login, event_id,
               description, evidence, is_candidate, created_at
        FROM findings
        {where}
        ORDER BY created_at DESC
    """
    with get_cursor(dict_cursor=True) as cur:
        cur.execute(sql, params)
        return [dict(r) for r in cur.fetchall()]
