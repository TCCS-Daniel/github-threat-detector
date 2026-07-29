import json

from collectors.github_client import get_result
from db.client import get_cursor
from db.queries import upsert_push_commit


def _push_events_for_repo(full_name: str) -> list[dict]:
    with get_cursor(dict_cursor=True) as cur:
        cur.execute(
            """
            SELECT id, payload->>'ref' AS ref, payload->>'head' AS head,
                   payload->>'before' AS before_sha
            FROM v_events_all
            WHERE repo_name = %s
              AND event_type = 'PushEvent'
              AND payload->>'head' IS NOT NULL
            ORDER BY created_at DESC
            """,
            (full_name,),
        )
        return [dict(r) for r in cur.fetchall()]


def _already_fetched(sha: str, repo_name: str) -> bool:
    with get_cursor() as cur:
        cur.execute(
            "SELECT 1 FROM push_commits WHERE sha = %s AND repo_name = %s",
            (sha, repo_name),
        )
        return cur.fetchone() is not None


def _store_commit(
    owner: str,
    repo: str,
    full_name: str,
    sha: str,
    ref: str | None,
    push_event_id: str | None,
    before_sha: str | None,
    unavailable: set[str],
) -> list[str] | None:
    if sha in unavailable:
        return None

    data, status = get_result(f"/repos/{owner}/{repo}/commits/{sha}")
    if not data:
        if status == 422:
            unavailable.add(sha)
        return None

    commit = data.get("commit", {})
    author_info = commit.get("author") or {}
    committer_info = commit.get("committer") or {}
    gh_author = data.get("author") or {}
    gh_committer = data.get("committer") or {}
    verification = commit.get("verification") or {}

    message = commit.get("message", "")
    headline = message.split("\n", 1)[0][:255]

    parents = [p["sha"] for p in data.get("parents", []) if p.get("sha")]
    raw_files = data.get("files") or []
    files_changed = [
        {"filename": f.get("filename"), "status": f.get("status")}
        for f in raw_files if f.get("filename")
    ]

    upsert_push_commit({
        "sha": sha,
        "repo_name": full_name,
        "push_event_id": push_event_id,
        "author_login": gh_author.get("login"),
        "author_email": author_info.get("email"),
        "author_name": author_info.get("name"),
        "author_date": author_info.get("date"),
        "committer_login": gh_committer.get("login"),
        "committer_email": committer_info.get("email"),
        "committer_name": committer_info.get("name"),
        "committer_date": committer_info.get("date"),
        "verified": verification.get("verified"),
        "verification_reason": verification.get("reason"),
        "parents": parents,
        "files_changed": json.dumps(files_changed) if files_changed else None,
        "message_headline": headline,
        "ref": ref,
        "before_sha": before_sha,
    })
    return parents


def _stored_parents(sha: str, repo_name: str) -> list[str]:
    with get_cursor() as cur:
        cur.execute(
            "SELECT parents FROM push_commits WHERE sha = %s AND repo_name = %s",
            (sha, repo_name),
        )
        row = cur.fetchone()
    return row[0] if row and row[0] else []


def _scan_missing_parents(
    owner: str,
    repo: str,
    full_name: str,
    parents: list[str],
    unavailable: set[str],
) -> int:
    count = 0
    for parent_sha in parents:
        if not parent_sha or parent_sha in unavailable or _already_fetched(parent_sha, full_name):
            continue
        if _store_commit(
            owner, repo, full_name, parent_sha, None, None, None, unavailable
        ) is not None:
            count += 1
    return count


def collect_push_commits(full_name: str, scan_parents: bool = False) -> int:
    owner, repo = full_name.split("/", 1)
    push_events = _push_events_for_repo(full_name)
    unavailable: set[str] = set()

    count = 0
    for event in push_events:
        head_sha = event["head"]
        if not head_sha or set(head_sha) == {"0"}:
            continue

        if head_sha in unavailable:
            continue

        if _already_fetched(head_sha, full_name):
            if scan_parents:
                count += _scan_missing_parents(
                    owner, repo, full_name,
                    _stored_parents(head_sha, full_name),
                    unavailable,
                )
            continue

        parents = _store_commit(
            owner, repo, full_name, head_sha,
            event["ref"], event["id"], event["before_sha"],
            unavailable,
        )
        if parents is None:
            continue
        count += 1

        if scan_parents:
            count += _scan_missing_parents(
                owner, repo, full_name, parents, unavailable
            )

    return count
