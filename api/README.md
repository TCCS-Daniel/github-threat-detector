# Investigation API

Local FastAPI backend for the findings investigation UI. Reads Postgres via
`DATABASE_URL` (same as the CLI). No auth in v1.

## Run

From the repo root (with deps installed into your venv):

```bash
pip install -r requirements.txt
uvicorn api.main:app --reload --port 8000
```

OpenAPI docs: http://127.0.0.1:8000/docs

## Endpoints

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/health` | Liveness |
| GET | `/api/orgs` | Distinct orgs from findings |
| GET | `/api/repos?org=` | Distinct repos |
| GET | `/api/findings?org=&repo=&severity=` | Severity-ordered list |
| GET | `/api/findings/{id}` | Detail + entities |
| GET | `/api/findings/{id}/related` | Facets: repo / user / tag / workflow |
| GET | `/api/timeline/repo?repo=&center=&window_days=7` | `v_audit_events` window |
| GET | `/api/timeline/compound?f1=&f2=&window_days=7` | Merged two-finding timeline + pins |

## UI

```bash
cd ui && npm install && npm run dev
```

Vite proxies `/api` to port 8000. Open http://127.0.0.1:5173
