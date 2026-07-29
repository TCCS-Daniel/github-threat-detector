import time

from collectors.github_client import get
from db.client import get_cursor
from db.queries import upsert_commit_author_search_batch


def _forged_emails() -> list[dict]:
    with get_cursor(dict_cursor=True) as cur:
        cur.execute(
            """
            SELECT author_email AS email, 'author' AS identity_kind,
                   min(repo_name) AS source_repo
            FROM push_commits
            WHERE author_login IS NULL
              AND author_email IS NOT NULL
              AND author_email != ''
              AND author_email != 'noreply@github.com'
              AND NOT author_email LIKE '%%@users.noreply.github.com'
            GROUP BY author_email
            UNION
            SELECT committer_email AS email, 'committer' AS identity_kind,
                   min(repo_name) AS source_repo
            FROM push_commits
            WHERE committer_login IS NULL
              AND committer_email IS NOT NULL
              AND committer_email != ''
              AND committer_email != 'noreply@github.com'
              AND NOT committer_email LIKE '%%@users.noreply.github.com'
            GROUP BY committer_email
            """
        )
        return [dict(r) for r in cur.fetchall()]


def collect_author_search(max_emails: int = 25, sleep_seconds: float = 2.0) -> int:
    emails = _forged_emails()

    count = 0
    for row in emails[:max_emails]:
        email = row["email"]
        data = get("/search/commits", {"q": f"author-email:{email}", "per_page": 100})
        if data:
            hits = []
            for item in data.get("items", []):
                repo = item.get("repository") or {}
                full_name = repo.get("full_name")
                sha = item.get("sha")
                if not full_name or not sha:
                    continue
                commit = item.get("commit") or {}
                author_info = commit.get("author") or {}
                hits.append({
                    "author_email": email,
                    "repo_full_name": full_name,
                    "sha": sha,
                    "author_name": author_info.get("name"),
                    "identity_kind": row["identity_kind"],
                    "source_repo": row["source_repo"],
                })
            count += upsert_commit_author_search_batch(hits)
        time.sleep(sleep_seconds)

    return count
