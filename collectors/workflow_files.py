import base64
from collectors.github_client import get, paginate
from db.client import get_cursor


def _repo_refs(owner: str, repo: str) -> list[tuple[str, str]]:
    refs: list[tuple[str, str]] = []
    for page in paginate(f"/repos/{owner}/{repo}/branches"):
        for branch in page:
            name = branch.get("name")
            sha = (branch.get("commit") or {}).get("sha")
            if name and sha:
                refs.append((f"refs/heads/{name}", sha))
    for page in paginate(f"/repos/{owner}/{repo}/tags"):
        for tag in page:
            name = tag.get("name")
            sha = (tag.get("commit") or {}).get("sha")
            if name and sha:
                refs.append((f"refs/tags/{name}", sha))
    return refs


def _fetch_blob(owner: str, repo: str, sha: str, cache: dict[str, str | None]) -> str | None:
    if sha in cache:
        return cache[sha]
    blob = get(f"/repos/{owner}/{repo}/git/blobs/{sha}")
    content = None
    if blob and blob.get("encoding") == "base64":
        content = base64.b64decode(blob["content"]).decode("utf-8", errors="replace")
    cache[sha] = content
    return content


def collect_workflow_files(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)

    upsert_sql = """
        INSERT INTO workflow_files (repo_name, ref, path, content, sha, fetched_at)
        VALUES (%s, %s, %s, %s, %s, now())
        ON CONFLICT (repo_name, ref, path) DO UPDATE SET
            content = EXCLUDED.content,
            sha = EXCLUDED.sha,
            fetched_at = now()
    """

    blob_cache: dict[str, str | None] = {}
    count = 0
    with get_cursor() as cur:
        for ref, commit_sha in _repo_refs(owner, repo):
            tree = get(f"/repos/{owner}/{repo}/git/trees/{commit_sha}", {"recursive": "1"})
            if not tree:
                continue
            for item in tree.get("tree", []):
                path = item.get("path", "")
                if not (
                    path.startswith(".github/workflows/")
                    and path.endswith((".yml", ".yaml"))
                    and item.get("type") == "blob"
                    and item.get("sha")
                ):
                    continue
                content = _fetch_blob(owner, repo, item["sha"], blob_cache)
                if content is None:
                    continue
                cur.execute(upsert_sql, (full_name, ref, path, content, item["sha"]))
                count += 1

    return count
