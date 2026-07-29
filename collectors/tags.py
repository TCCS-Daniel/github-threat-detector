from collectors.github_client import get, paginate
from db.queries import upsert_repo_tag, insert_tag_drift


def collect_repo_tags(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)
    count = 0

    for page in paginate(f"/repos/{owner}/{repo}/git/refs/tags"):
        for ref in page:
            ref_name = ref.get("ref", "")
            tag_name = ref_name.removeprefix("refs/tags/")
            obj = ref.get("object", {})
            tag_sha = obj.get("sha", "")
            obj_type = obj.get("type", "")

            commit_sha = None
            tag_type = "lightweight"

            if obj_type == "tag":
                tag_type = "annotated"
                tag_detail = get(f"/repos/{owner}/{repo}/git/tags/{tag_sha}")
                if tag_detail:
                    inner = tag_detail.get("object", {})
                    commit_sha = inner.get("sha")
            elif obj_type == "commit":
                commit_sha = tag_sha

            old_sha = upsert_repo_tag({
                "repo_name": full_name,
                "tag_name": tag_name,
                "tag_sha": tag_sha,
                "commit_sha": commit_sha,
                "tag_type": tag_type,
            })

            if old_sha:
                insert_tag_drift(full_name, tag_name, old_sha, tag_sha)

            count += 1

    return count
