# Findings investigation UI

React + Vite front-end for correlating analyzer findings (list, graph, timeline).

## Run

From repo root, start the API first:

```bash
.venv/bin/uvicorn api.main:app --reload --port 8000
```

Then:

```bash
cd ui
npm install
npm run dev
```

Vite serves on `http://127.0.0.1:5173` and proxies `/api` → `http://127.0.0.1:8000`.

## Scripts

- `npm run dev` — local UI
- `npm run build` — typecheck + production bundle
- `npm run lint` — oxlint
