from datetime import datetime, timezone

from collectors.github_client import get_result, paginate
from db.client import get_cursor
from db.queries import upsert_workflow_run


def _completed_run_ids_to_verify(full_name: str) -> list[str]:
    with get_cursor() as cur:
        cur.execute(
            """
            SELECT DISTINCT e.payload#>>'{workflow_run,id}' AS run_id
            FROM events_webhook_org e
            JOIN workflow_runs w
              ON w.id = e.payload#>>'{workflow_run,id}'
            WHERE e.repo_name = %s
              AND e.event_type = 'WorkflowRunEvent'
              AND e.payload->>'action' = 'completed'
              AND e.created_at > now() - interval '7 days'
              AND COALESCE(w.status, '') <> 'deleted'
            """,
            (full_name,),
        )
        return [row[0] for row in cur.fetchall() if row[0]]


def _reconcile_deleted_runs(owner: str, repo: str, full_name: str, source: str) -> int:
    marked = 0
    now = datetime.now(timezone.utc).isoformat()
    for run_id in _completed_run_ids_to_verify(full_name):
        _data, status = get_result(f"/repos/{owner}/{repo}/actions/runs/{run_id}")
        if status != 404:
            continue
        upsert_workflow_run(
            {
                "id": run_id,
                "_repo_name": full_name,
                "status": "deleted",
                "conclusion": None,
                "updated_at": now,
            },
            source,
        )
        marked += 1
    return marked


def collect_workflow_runs(full_name: str, status: str | None = None) -> int:
    owner, repo = full_name.split("/", 1)
    source = f"{owner}_{repo}_actions"
    params = {}
    if status:
        params["status"] = status

    total = 0
    for page in paginate(f"/repos/{owner}/{repo}/actions/runs", params):
        runs = page if isinstance(page, list) else page.get("workflow_runs", [])
        for run in runs:
            run["_repo_name"] = full_name
            upsert_workflow_run(run, source)
            total += 1

    total += _reconcile_deleted_runs(owner, repo, full_name, source)
    return total
