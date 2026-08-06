# GitHub Threat Detector

A supply chain threat detection tool that collects GitHub repository activity and git-level signals, then runs heuristic analyzers to identify indicators of compromise. Ships with **33 detection rules** across 1 analyzer module (`analyzers/detection_queries/`).

## Setup

```bash
pip install -r requirements.txt
cp .env.example .env
# Edit .env with your GITHUB_TOKEN, DATABASE_URL, and either
# GITHUB_REPOS (explicit repos) or GITHUB_ORGS + TARGET_REPO_PREFIX (org discovery)
```

Requires PostgreSQL. Initialize the schema:

```bash
python cli.py init-db
```

## Usage

### Collect

```bash
# Basic event collection
python cli.py collect --repos owner/repo

# Full collection with all optional collectors
python cli.py collect --repos owner/repo \
  --actions --contributors --workflow-files --commits --scan-parents \
  --tags --git-inspect --activities --snapshots --author-search

# Org-level events
python cli.py collect --orgs my-org

# Discover all repos in an org whose name starts with a prefix
# (e.g. every supplychain-labs/sim* repo) and collect against each
python cli.py collect --orgs supplychain-labs --repo-prefix sim \
  --commits --tags --activities
```

### Analyze

```bash
# Run all analyzers
python cli.py analyze

# Filter by repo or specific rules
python cli.py analyze --repos owner/repo
python cli.py analyze --rules flip-flop-tag,symlink-traversal
```

### Report

```bash
python cli.py report
python cli.py report --severity critical,high --since 7d
python cli.py report --format json
```

### Reset

```bash
# Drop all tables/views and re-apply db/schema.sql (destructive)
python cli.py reset-db
```

### Investigation UI

Local one-page UI over `findings` and `v_audit_events`: severity-ordered findings, related facets (repo / user / tag / workflow / commit), and repo or two-finding pinned timelines.

```bash
# terminal 1 — API (uses DATABASE_URL)
uvicorn api.main:app --reload --port 8000

# terminal 2 — UI (proxies /api → :8000)
cd ui && npm install && npm run dev
```

Open http://127.0.0.1:5173 — see [`api/README.md`](api/README.md).

The topbar's **Collect + Analyze** button triggers a background collect + analyze
run over the configured repos/orgs (`POST /api/run`); set `RUN_COLLECTORS` to
enable optional collectors for it (e.g. `RUN_COLLECTORS=commits,tags,activities`).
The findings list refreshes automatically when the run finishes.

## Collectors

| Collector           | CLI Flag           | Source                                                                                               | Data Stored                                                                                                                                                                                     |
| ------------------- | ------------------ | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `events.py`         | _(always runs)_    | GitHub Events API                                                                                    | `events_api` / `v_events_all` -- PushEvent, PullRequestEvent, ForkEvent, etc.                                                                                                                   |
| `actions.py`        | `--actions`        | GitHub Actions API                                                                                   | `workflow_runs` -- workflow run status, conclusion, actor                                                                                                                                       |
| `contributors.py`   | `--contributors`   | GitHub Contributors API                                                                              | `repo_contributors` -- actor login and contribution count                                                                                                                                       |
| `workflow_files.py` | `--workflow-files` | GitHub Branches/Tags + Git Trees/Blobs APIs                                                          | `workflow_files` -- `.github/workflows/*.yml` content for every branch and tag                                                                                                                  |
| `commits.py`        | `--commits`        | GitHub Commits API                                                                                   | `push_commits` -- commit metadata for every push head (author/committer identity, dates, GPG verification). Add `--scan-parents` to also ingest each head's parent commit(s) for lineage rules  |
| `tags.py`           | `--tags`           | GitHub Git Refs API                                                                                  | `repo_tags` + `repo_tags_history` -- tag SHAs and drift detection                                                                                                                               |
| `git_repo.py`       | `--git-inspect`    | Local `git clone --bare`                                                                             | `git_repo_checks` -- replace refs, gitattributes, symlinks, invisible unicode, tag provenance                                                                  |
| `activities.py`     | `--activities`     | GitHub Repository Activity API                                                                       | `repo_activities` -- force-pushes, branch/tag deletions, ref changes                                                                                                                            |
| `snapshots.py`      | `--snapshots`      | GitHub repo config APIs (hooks, branches, secrets, collaborators, releases, workflows) + org members | `git_repo_checks` (state) + `events_snapshot` (drift events)                                                                                                                                    |
| `author_search.py`  | `--author-search`  | GitHub Commit Search API                                                                             | `commit_author_search` -- cross-owner hits for unresolvable author/committer emails found in `push_commits` (own scheduler; see [Author enrichment](#author-enrichment-collector)) |
| `repos.py`          | `--repo-prefix`    | GitHub Org Repos API                                                                                 | *(discovery only -- resolves `org/name*` into the target repo list)* |

## Analyzer Rules

### Detection Queries (`analyzers/detection_queries/`)

SQL-driven rules grounded in the attack simulations under [`simulations/`](simulations/). Each rule is a `.sql` file under `rules/` (or staged under `rules/candidates/`) with a small metadata header; a generic runner executes it and writes findings. See [`analyzers/detection_queries/README.md`](analyzers/detection_queries/README.md) for how to add one. Severity labels reflect isolated-finding maliciousness probability.

| Rule ID                               | Severity | Description                                                                                                             |
| ------------------------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------- |
| `workflow-secret-base64-exfil`        | critical | Workflow echoes secrets through base64 (log exfiltration pattern)                                                       |
| `flip-flop-tag`                       | critical | Tag moved away from a SHA and back (flip-flop tag poisoning, via push events)                                           |
| `flip-flop-tag-history`               | critical | Tag moved to a new SHA and later back (flip-flop tag poisoning, via tag history)                                        |
| `mass-tag-force-push-burst`           | critical | 5+ tags force-pushed within a 5-minute window (via push events)                                                         |
| `mass-tag-force-push-history`         | critical | 5+ tags rewritten within a 5-minute window (via tag history)                                                            |
| `git-replace-ref`                     | critical | Repository contains `refs/replace/*` that silently substitute commit objects                                            |
| `gitattributes-filter-abuse`          | critical | `.gitattributes` contains non-LFS filter/smudge/clean directives                                                        |
| `symlink-traversal`                   | critical | Symlink targets `.git/hooks` or deep traversal outside the repo tree                                                    |
| `oidc-workflow-nondefault-unverified` | high     | Workflow granting OIDC token pushed to a non-default ref via an unverified commit                                       |
| `oidc-workflow-push-default`          | high     | OIDC-granting workflow pushed directly to the default branch                                                            |
| `workflow-run-deleted`                | high     | Workflow run completed but is absent/null in the runs API (run deleted to hide activity)                                |
| `cross-owner-forged-author`           | high     | Same forged author email appears across 2+ unrelated owners within 24 hours (via `commit_author_search`)                |
| `release-asset-time-skew`             | high     | Release where one asset's `created_at` is 1h+ later than the earliest sibling asset (post-publish artifact replacement) |
| `pr-instant-close`                    | high     | Fork PR opened and closed within 10 seconds (automated exploit trigger)                                                 |
| `invisible-unicode-in-diff`           | high     | Commit diffs contain invisible Unicode characters (ref: GlassWorm)                                                      |
| `tag-from-nonexisting-branch`         | high     | Tag resolves to a commit on no existing branch                                                                          |
| `many-tags-same-commit-history`       | high     | 3+ tags moved to the same commit (via tag history)                                                                      |
| `many-tags-same-parent`               | high     | 2+ tag refs share the same parent commit (fabricated tag commits)                                                       |
| `direct-workflow-push-default`        | medium   | Workflow file pushed directly to the default branch                                                                     |
| `risky-workflow-pwn-request`          | medium   | Workflow combines an untrusted trigger with attacker-controlled checkout/input (pwn request)                            |
| `pr-rapid-state-change`               | medium   | PR opened/closed/reopened 3+ times within 5 minutes (workflow trigger probing)                                          |
| `forged-author-unresolvable-email`    | medium   | Push whose commit author resolves to no GitHub account (forged author)                                                  |
| `ghost-committer`                     | medium   | Commit committer email does not resolve to any GitHub account                                                           |
| `mass-tag-deletion`                   | medium   | 5+ tags deleted by the same actor within 60 minutes (via Repository Activity API)                                       |
| `many-tags-same-commit`               | medium   | 2+ tags pushed pointing to the same commit                                                                              |
| `same-tree-multiple-tags`             | medium   | 3+ tags point at commits sharing the same tree (duplicated tag content)                                                 |
| `tag-parent-commit-future`            | medium   | Tag commit was committed before its parent (impossible lineage)                                                         |
| `unverified-commit-protected-ref`     | medium   | Unverified commit on a protected ref in a repo where 80%+ of commits are signed                                         |
| `author-committer-mismatch`           | low      | Author and committer differ in both name and email (identity spoofing via `--author`)                                   |
| `author-differs-from-pusher`          | low      | Commit author differs from the pusher                                                                                   |
| `action-mutable-ref`                  | low      | Third-party GitHub Actions pinned to mutable tags instead of SHA hashes (tag poisoning risk)                            |
| `tag-committer-differs-from-pusher`   | low      | Tag committer name differs from the pusher                                                                              |
| `unverified-commits-tags-main`        | low      | Unverified commit on a tag or main/master ref                                                                           |

## Architecture

```
GitHub REST API / git clone / webhooks
                 │
                 ▼
           collectors/  ──►  PostgreSQL  ──►  analyzers  ──►  findings
                 │                │
                 │                └──► cli.py report
                 │
     ┌───────────┴───────────────────────────────────────┐
     │         three scheduled collectors                │
     │  Snapshot │ Git forensics │ Author enrichment     │
     │  (see below)                                      │
     └───────────────────────────────────────────────────┘
```

All data flows through PostgreSQL. Collectors and the webhook receiver write raw events into per-source tables (exposed together via the `v_events_all` view); analyzers read from those tables/views and write findings.

Locally, `cli.py` orchestrates collection, full analysis (all 33 rules), and reporting. In production the same collectors run on independent schedulers; each collector writes its tables and then runs only the SQL rules that depend on that data (see [Scheduled collectors](#scheduled-collectors)). All detection rules are SQL-driven; CLI `analyze` and the scheduled collectors run the same rule set.

### Scheduled collectors

Three collectors share the same pattern — **collect → write tables → run matching rules** — but differ in scope and data source. Each has its own scheduler so heavy or rate-limited work does not block the others.

| Collector | Scheduler (default) | Scope | Writes | Rules after collect |
|-----------|---------------------|-------|--------|---------------------|
| Snapshot | every ~3 min | Target repos / orgs | events, commits, tags, activities, workflows, contributors, config snapshots | 27 default SQL rules |
| Git forensics | every ~5 min | Target repos (local git clone) | `git_repo_checks` (forensics check types) | 5 forensics SQL rules |
| Author enrichment | every ~5 min | Unresolved emails already in DB (not scoped to target repos) | `commit_author_search` | `cross-owner-forged-author` only |

#### Snapshot collector

Per-repo / per-org polling of GitHub APIs for the configured targets. Produces most of the tables the default detection rules read.

```
scheduler (~3 min)
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│  SnapshotCollector                                        │
│                                                           │
│  for each target repo:                                    │
│    events, commits (+ parents), tags, activities,         │
│    workflow runs/files, contributors, config snapshots    │
│  for each target org:                                     │
│    org members                                            │
│                                                           │
│  → PostgreSQL (events_*, push_commits, repo_tags, …)      │
│  → run 27 default SQL rules → findings                    │
└───────────────────────────────────────────────────────────┘
```

CLI equivalent: `python cli.py collect --repos … --commits --scan-parents --tags --activities --actions --workflow-files --contributors --snapshots` then `python cli.py analyze` (minus forensics / author-enrichment rules).

#### Git forensics collector

Per-repo deep inspect via local `git clone --bare`. Separated because clones are heavy and only a small set of rules need those signals.

```
scheduler (~5 min)
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│  GitForensicsCollector                                    │
│                                                           │
│  for each target repo:                                    │
│    clone --bare → integrity checks                        │
│    (replace refs, gitattributes, symlinks,                │
│     invisible unicode, tag provenance)                    │
│                                                           │
│  → PostgreSQL (git_repo_checks)                           │
│  → run 5 forensics SQL rules → findings                   │
│     tag-from-nonexisting-branch, git-replace-ref,         │
│     gitattributes-filter-abuse, symlink-traversal,        │
│     invisible-unicode-in-diff                             │
└───────────────────────────────────────────────────────────┘
```

CLI equivalent: `python cli.py collect --repos … --git-inspect` then `python cli.py analyze` with the forensics rule IDs above.

#### Author enrichment collector

Global enrichment on top of `push_commits`, not a per-repo loop. Reads unresolved author/committer emails from the DB, searches GitHub for the same identity under other owners, then runs the one rule that needs that table.

**Unresolved** = `author_login` / `committer_login` is NULL (email did not map to a GitHub user). Bot/noreply addresses are skipped.

```
                    ┌─────────────────────────────┐
                    │  SnapshotCollector          │
                    │  commits → push_commits     │
                    └──────────────┬──────────────┘
                                   │
                                   │ unresolved emails
                                   │ (login IS NULL)
                                   ▼
scheduler (~5 min)
        │
        ▼
┌───────────────────────────────────────────────────────────┐
│  AuthorEnrichmentCollector                                │
│                                                           │
│  1. SELECT forged emails from push_commits                │
│  2. for each email (batched, rate-limited):               │
│       search commits by author-email                      │
│  3. upsert hits → commit_author_search                    │
│  4. run cross-owner-forged-author                         │
│       → finding if same email hits ≥2 owners in 24h       │
└───────────────────────────────────────────────────────────┘
                                   │
                                   ▼
                              findings
```

**Why its own scheduler.** Search is not scoped to target repos/orgs — it can return commits under arbitrary owners — and is rate-limited. Running it on the Snapshot schedule would couple that work to the per-repo collect loop; a dedicated collector keeps Snapshot fast and only runs the `data_source: author_enrichment` rule after `commit_author_search` is updated.

CLI equivalent: `python cli.py collect --author-search` (after commits exist in `push_commits`), then `python cli.py analyze --rules cross-owner-forged-author`.

## Deployment

### Production (on-host)

A single uvicorn process serves the API and the built investigation UI on
port 8000, backed by the host's PostgreSQL. See [`DEPLOYMENT.md`](DEPLOYMENT.md)
for the full setup and the systemd unit ([`deploy/threat-detector.service`](deploy/threat-detector.service)).

```bash
cd ui && npm ci && npm run build && cd ..
uvicorn api.main:app --host 0.0.0.0 --port 8000
```

### AWS (webhook receiver + scheduled collectors)

A SAM stack (`webhook/template.yaml`) runs the webhook receiver and the three scheduled collectors on AWS:

| Component | Trigger | Purpose |
|-----------|---------|---------|
| `WebhookReceiver` | HTTP endpoint | Verifies the HMAC signature and writes webhook events into `events_webhook_*` |
| `SnapshotCollector` | scheduler (default every 3 min) | Snapshot collector — see above |
| `GitForensicsCollector` | scheduler (default every 5 min) | Git forensics collector — see above |
| `AuthorEnrichmentCollector` | scheduler (default every 5 min) | Author enrichment collector — see above |
| `DBInstance` | — | RDS PostgreSQL backing store |

Apply `db/schema.sql` once after first deploy (collectors do not migrate schema). The target repo list is resolved from the `TargetRepos`, `TargetOrgs`, and `TargetRepoPrefix` stack parameters (mapped to the `TARGET_*` env vars). Profile, region, and stack name are pinned in `deploy/aws.env`; deploy with `webhook/deploy.sh`.

## Database Tables

| Table                     | Contents                                                                                                                                                                                                                                                                                                           | Source of truth                                                                                                         | Populated by                                                                                                                                                               | Notes                                                                                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `events_webhook_org`      | Deliveries from an org-level webhook (all event types for every repo in the org, plus org membership/team events)                                                                                                                                                                                                  | GitHub org webhook (split by `X-GitHub-Hook-Installation-Target-Type` header)                                           | `WebhookReceiver` lambda                                                                                                                                                   | Single source (push-driven)                                                                                                                                                   |
| `events_webhook_repo`     | Deliveries from a repo-level webhook (push, pull_request, issues, etc.)                                                                                                                                                                                                                                            | GitHub repo webhook (split by `X-GitHub-Hook-Installation-Target-Type` header)                                          | `WebhookReceiver` lambda                                                                                                                                                   | Single source (push-driven)                                                                                                                                                   |
| `events_api`              | Public events polled from GitHub                                                                                                                                                                                                                                                                                   | GitHub Events API (`/repos/{o}/{r}/events`, `/orgs/{org}/events`)                                                       | `events.py` (CLI + `SnapshotCollector`)                                                                                                                                    | Single source (pull-driven)                                                                                                                                                   |
| `events_snapshot`         | Synthetic drift events (`Added`/`Removed`/`Modified`) emitted when repo config changes between snapshot runs                                                                                                                                                                                                       | Derived from `git_repo_checks` diffs of hooks / branches / secrets / collaborators / releases / workflows / org members | `snapshots.py` (`SnapshotCollector`)                                                                                                                                       | Derived, not a raw source; only emitted on change                                                                                                                             |
| `workflow_files`          | `.github/workflows/*.yml` file content per ref (`refs/heads/*` and `refs/tags/*`)                                                                                                                                                                                                                                  | GitHub Branches/Tags + Git Trees/Blobs APIs                                                                             | `workflow_files.py` (CLI + `SnapshotCollector`)                                                                                                                            | Single source (API); one row per (repo, ref, path)                                                                                                                            |
| `repo_contributors`       | Contributor login + contribution count                                                                                                                                                                                                                                                                             | GitHub Contributors API                                                                                                 | `contributors.py` (CLI + `SnapshotCollector`)                                                                                                                              | Single source (API)                                                                                                                                                           |
| `workflow_runs`           | GitHub Actions run metadata (status, conclusion, actor)                                                                                                                                                                                                                                                            | GitHub Actions API                                                                                                      | `actions.py` (CLI + `SnapshotCollector`)                                                                                                                                   | Single source (API)                                                                                                                                                           |
| `push_commits`            | Commit metadata (author/committer identity, dates, GPG verification, parents, `files_changed`, message headline)                                                                                                                                                                                                   | GitHub Commits API (`/repos/{o}/{r}/commits/{sha}`)                                                                     | `commits.py` (CLI + `SnapshotCollector`)                                                                                                                                   | Two-stage: SHAs are discovered from `v_events_all` `PushEvent`s, then **enriched** by fetching each commit from the Commits API. `--scan-parents` also fetches parent lineage |
| `commit_author_search`    | Cross-owner GitHub Search results for suspicious author emails (ghost identities) surfaced in `push_commits`                                                                                                                                                                                                       | GitHub Commit Search API (`/search/commits?q=author-email:...`)                                                         | `author_search.py` (CLI + `AuthorEnrichmentCollector`)                                                                                                                     | **Enrichment on top of `push_commits`** — reads unresolved author/committer emails and searches GitHub for other repos using them                                             |
| `repo_tags`               | Current tag → SHA mapping (tag name, tag SHA, commit SHA, tag type)                                                                                                                                                                                                                                                | GitHub Git Refs API (`/repos/{o}/{r}/git/matching-refs/tags`)                                                           | `tags.py` (CLI + `SnapshotCollector`)                                                                                                                                      | Single source (API); diffs between runs emit rows into `repo_tags_history`                                                                                                    |
| `repo_tags_history`       | Tag SHA drift log (old SHA → new SHA)                                                                                                                                                                                                                                                                              | Derived from `repo_tags` diffs between runs                                                                             | `tags.py`                                                                                                                                                                  | Derived / drift log on top of `repo_tags`                                                                                                                                     |
| `repo_activities`         | Repository Activity entries (force-pushes, branch/tag deletions, ref changes)                                                                                                                                                                                                                                      | GitHub Repository Activity API (`/repos/{o}/{r}/activity`)                                                              | `activities.py` (CLI + `SnapshotCollector`)                                                                                                                                | Single source (API)                                                                                                                                                           |
| `git_repo_checks`         | Per-`check_type` JSONB results. **Forensics** rows: `replace_refs`, `gitattributes`, `symlinks`, `unicode_artifacts`, `tag_provenance`. **Config-snapshot** rows: `hooks`, `branches`, `secrets`, `collaborators`, `releases`, `workflows`, `org_members` (last-seen state) | Forensics: local `git clone --bare`. Config snapshots: GitHub repo config APIs                                          | Forensics: `git_repo.py` (`GitForensicsCollector`). Config snapshots: `snapshots.py` (`SnapshotCollector`)                                                                 | Multi-source table keyed by `check_type`; config-snapshot rows also drive `events_snapshot` drift emission                                                                    |
| `webhook_deliveries`      | Audit log of every webhook delivery received (`delivery_id`, `source`, `event_type`)                                                                                                                                                                                                                               | GitHub webhook headers (`X-GitHub-Delivery`, `X-GitHub-Event`)                                                          | `WebhookReceiver` lambda                                                                                                                                                   | Single source (webhook)                                                                                                                                                       |
| `findings`                | Analyzer output — one row per fired rule (`rule_id`, severity, evidence, `is_candidate`)                                                                                                                                                                                                                           | Derived by analyzers reading the tables above                                                                           | CLI `analyze` (all 33 rules); SnapshotCollector (27 SQL rules); GitForensicsCollector (5 forensics SQL rules); AuthorEnrichmentCollector (`cross-owner-forged-author` SQL) | Derived / analytical output                                                                                                                                                   |
| `v_events_all` _(view)_   | Union of `events_webhook_org`, `events_webhook_repo`, `events_api`, `events_snapshot` (adds `source` column)                                                                                                                                                                                                       | View over event tables                                                                                                  | —                                                                                                                                                                          | Analyzers query this instead of individual event tables                                                                                                                       |
| `v_audit_events` _(view)_ | Cross-source audit timeline joining `v_events_all` + `repo_activities` + `push_commits` + `repo_tags_history` + `git_repo_checks` (forensics rows) + `webhook_deliveries`                                                                                                                                          | View                                                                                                                    | —                                                                                                                                                                          | Used for reporting / audit queries                                                                                                                                            |

## Environment Variables

| Variable             | Description                                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `GITHUB_TOKEN`       | GitHub personal access token (increases API rate limits, required for private repos)                                     |
| `DATABASE_URL`       | PostgreSQL connection string (default: `postgresql://postgres@localhost:5432/threat_detector`)                           |
| `GITHUB_REPOS`       | Comma-separated default repos (used when `--repos` is not passed)                                                        |
| `GITHUB_ORGS`        | Comma-separated default orgs (used when `--orgs` is not passed; falls back to `TARGET_ORGS`)                             |
| `TARGET_REPOS`       | Lambda/stack target repos (preferred over `GITHUB_REPOS` in collector Lambdas)                                           |
| `TARGET_ORGS`        | Lambda/stack target orgs (preferred over `GITHUB_ORGS` in collector Lambdas)                                             |
| `TARGET_REPO_PREFIX` | Restrict org discovery to repos whose name starts with this prefix (e.g. `sim`; used when `--repo-prefix` is not passed) |
| `RUN_COLLECTORS`     | Optional collectors for the UI's Collect + Analyze button (comma-separated CLI flag names, e.g. `commits,scan-parents,tags`) |
| `CORS_ALLOW_ORIGINS` | Comma-separated origins allowed to call the API cross-origin (unset = same-origin only)                                  |
