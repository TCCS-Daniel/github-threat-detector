from __future__ import annotations

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from api import queries

app = FastAPI(title="GitHub Threat Detector Investigation API", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/api/health")
def health():
    return {"ok": True}


@app.get("/api/orgs")
def orgs():
    return {"orgs": queries.list_orgs()}


@app.get("/api/repos")
def repos(org: str | None = None):
    return {"repos": queries.list_repos(org=org)}


@app.get("/api/findings")
def findings(
    org: str | None = None,
    repo: str | None = None,
    severity: list[str] | None = Query(default=None),
    since: str | None = Query(default=None, description="Relative window: 15m, 1h, 4h, 1d, 7d"),
):
    try:
        return {
            "findings": queries.list_findings(
                org=org, repo=repo, severity=severity, since=since
            )
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/findings/{finding_id}")
def finding_detail(finding_id: int):
    row = queries.get_finding(finding_id)
    if row is None:
        raise HTTPException(status_code=404, detail="finding not found")
    return row


@app.get("/api/findings/{finding_id}/related")
def finding_related(
    finding_id: int,
    since: str | None = Query(default=None, description="Relative window: 15m, 1h, 4h, 1d, 7d"),
    repo: str | None = Query(default=None),
):
    row = queries.related_findings(finding_id, since=since, repo=repo)
    if row is None:
        raise HTTPException(status_code=404, detail="finding not found")
    return row


@app.get("/api/timeline/repo")
def timeline_repo(
    repo: str = Query(...),
    center: str | None = None,
    window_days: int = Query(default=7, ge=1, le=90),
):
    return queries.repo_timeline(repo=repo, center=center, window_days=window_days)


@app.get("/api/timeline/compound")
def timeline_compound(
    f1: int = Query(...),
    f2: int = Query(...),
    window_days: int = Query(default=7, ge=1, le=90),
):
    row = queries.compound_timeline(f1_id=f1, f2_id=f2, window_days=window_days)
    if row is None:
        raise HTTPException(status_code=404, detail="finding not found")
    return row
