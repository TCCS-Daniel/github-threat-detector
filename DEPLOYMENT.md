# Production deployment

In production a single uvicorn process serves both the API and the built
investigation UI (from `ui/dist`) on one port, backed by the host's
PostgreSQL. No container is involved — the project runs directly on the host.

## Setup

```bash
# 1. Build the UI once (rebuild after UI changes)
cd ui && npm ci && npm run build && cd ..

# 2. Install backend deps
pip install -r requirements.txt

# 3. Configure
cp .env.example .env   # set GITHUB_TOKEN, DATABASE_URL, repos/orgs

# 4. Serve API + UI
uvicorn api.main:app --host 0.0.0.0 --port 8000
```

The schema is applied automatically at startup, so a fresh database works
immediately — populate it with the **Collect + Analyze** button in the UI or
the CLI (`python cli.py collect ... && python cli.py analyze`).

## Run as a service

A systemd unit is provided in [`deploy/threat-detector.service`](deploy/threat-detector.service):

```bash
cp deploy/threat-detector.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now threat-detector
```

Logs: `journalctl -u threat-detector -f`.

## Scheduled pipeline runs

A systemd timer triggers the collect + analyze pipeline automatically every
4–5 hours (00:00, 05:00, 10:00, 15:00, 20:00, ±10 min jitter) by POSTing to
`/api/run` — the same job the UI button starts, so progress is visible in the
UI and the single-run guard prevents overlap:

```bash
cp deploy/threat-detector-run.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now threat-detector-run.timer
```

- Check the schedule: `systemctl list-timers threat-detector-run.timer`
- Run it manually: `systemctl start threat-detector-run`
- Change the cadence: edit `OnCalendar=` in the timer (e.g. `00/4:00:00` for
  every 4 hours), then `systemctl daemon-reload`.
- `Persistent=true` fires a missed run at boot if the host was off when one
  was due.

## Configuration

| Variable | Purpose |
| --- | --- |
| `GITHUB_TOKEN` | GitHub PAT used by all collectors |
| `DATABASE_URL` | Postgres DSN |
| `GITHUB_REPOS` / `GITHUB_ORGS` | Default collection targets |
| `TARGET_REPO_PREFIX` | Only collect org repos whose name starts with this prefix |
| `RUN_COLLECTORS` | Optional collectors for the UI's Collect + Analyze button, e.g. `commits,scan-parents,tags,activities` |
| `CORS_ALLOW_ORIGINS` | Comma-separated origins; only needed if the UI is hosted on a different origin than the API |

## The Collect + Analyze button

`POST /api/run` starts a background job (one at a time) that collects events
for the configured repos/orgs — plus any collectors listed in
`RUN_COLLECTORS` — then runs all analyzers. `GET /api/run/status` reports
progress; the UI polls it and refreshes the findings list when the job
finishes.

## Operational notes

- **No authentication**: the API has none, so restrict access at the network
  layer (firewall, VPN, allowlist) or put an authenticating reverse proxy
  (nginx, Caddy) in front — which is also the place to terminate TLS for
  anything internet-facing.
- **Scheduled collection**: handled by `threat-detector-run.timer` (see
  above); the UI button remains for on-demand runs between scheduled ones.
- **Health check**: `GET /api/health`.
- **Workers**: the run job holds its state in process memory, so run a single
  uvicorn worker (the default). Scale collection via the CLI if needed.
- **Backups**: standard `pg_dump` of the `threat_detector` database.
