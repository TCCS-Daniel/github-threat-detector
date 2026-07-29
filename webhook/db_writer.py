import json
import os
from typing import Any

import psycopg2

_conn = None


def _get_conn():
    global _conn
    if _conn is None or _conn.closed:
        _conn = psycopg2.connect(os.environ["DATABASE_URL"])
    return _conn


def record_delivery(delivery_id: str, source: str, event_type: str, repo_name: str | None) -> None:
    sql = """
        INSERT INTO webhook_deliveries (delivery_id, source, event_type, repo_name)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (delivery_id, source) DO NOTHING
    """
    conn = _get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, (delivery_id, source, event_type, repo_name))
        conn.commit()
    except Exception:
        conn.rollback()
        raise


SOURCE_TO_TABLE = {
    "webhook_org": "events_webhook_org",
    "webhook_repo": "events_webhook_repo",
}


def upsert_github_event(row: dict[str, Any]) -> None:
    source = row.get("source", "webhook_repo")
    table = SOURCE_TO_TABLE.get(source)
    if not table:
        raise ValueError(f"Unknown webhook source: {source}")
    sql = f"""
        INSERT INTO {table}
            (id, event_type, actor_login, actor_id, repo_name, org_login,
             payload, created_at)
        VALUES
            (%(id)s, %(event_type)s, %(actor_login)s, %(actor_id)s, %(repo_name)s,
             %(org_login)s, %(payload)s, %(created_at)s)
        ON CONFLICT (id) DO NOTHING
    """
    conn = _get_conn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, {
                "id": row["id"],
                "event_type": row["event_type"],
                "actor_login": row.get("actor_login"),
                "actor_id": row.get("actor_id"),
                "repo_name": row["repo_name"],
                "org_login": row.get("org_login"),
                "payload": json.dumps(row.get("payload") or {}),
                "created_at": row.get("created_at"),
            })
        conn.commit()
    except Exception:
        conn.rollback()
        raise
