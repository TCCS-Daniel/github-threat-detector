from collectors.github_client import paginate_link
from db.queries import upsert_repo_activity_batch


def collect_repo_activities(full_name: str) -> int:
    owner, repo = full_name.split("/", 1)
    total = 0
    for page in paginate_link(f"/repos/{owner}/{repo}/activity"):
        for activity in page:
            activity["_repo_name"] = full_name
            activity["_source"] = "activities_api"
        total += upsert_repo_activity_batch(page)
    return total
