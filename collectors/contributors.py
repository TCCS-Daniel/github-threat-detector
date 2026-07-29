from collectors.github_client import paginate
from db.client import get_cursor


def collect_contributors(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)
    rows: list[tuple] = []
    for page in paginate(f"/repos/{owner}/{repo}/contributors", {"anon": "false"}):
        for c in page:
            login = c.get("login")
            if login:
                rows.append((full_name, login, c.get("contributions", 0)))

    if not rows:
        return 0

    sql = """
        INSERT INTO repo_contributors (repo_name, actor_login, contributions, fetched_at)
        VALUES (%s, %s, %s, now())
        ON CONFLICT (repo_name, actor_login) DO UPDATE SET
            contributions = EXCLUDED.contributions,
            fetched_at = now()
    """
    with get_cursor() as cur:
        for row in rows:
            cur.execute(sql, row)
    return len(rows)
