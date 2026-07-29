# GitHub Webhook Receiver

Lambda + RDS Postgres that receives GitHub webhook deliveries, verifies the
HMAC signature, normalizes the payload into the same shape used by
`collectors/events.py`, and INSERTs into `events_webhook_org` or
`events_webhook_repo` (depending on whether the delivery came from an
org-level or repo-level webhook), plus an audit row in `webhook_deliveries`.
Once data is flowing, `python cli.py analyze` and `python cli.py report` work
unchanged against the same DB via the `v_events_all` view.

## Layout

```
webhook/
├── handler.py        # Lambda entrypoint (HMAC verify + insert)
├── normalizer.py     # webhook headers + body -> normalized event row
├── db_writer.py      # psycopg2 INSERT ... ON CONFLICT DO NOTHING
├── requirements.txt  # psycopg2-binary
├── template.yaml     # SAM: webhook receiver + scheduled collector Lambdas + RDS
├── deploy.sh         # build + deploy against the pinned profile/region
└── README.md
```

The SAM template also defines the scheduled collector Lambdas
(`SnapshotCollector`, `GitForensicsCollector`, `AuthorEnrichmentCollector`)
and the Secrets Manager secret holding the GitHub PAT — see the Deployment
section of the [root README](../README.md).

## Prerequisites

- AWS CLI configured (`aws configure`) against the playground account
- SAM CLI installed (`brew install aws-sam-cli`)
- Docker running (SAM uses it for the arm64 Lambda build)
- `psql` available locally to apply the schema once

## Deploy

Profile, region, and stack name are read from `deploy/aws.env` (gitignored).  
Copy [`deploy/aws.env.example`](../deploy/aws.env.example) and fill in your values before running `./deploy.sh`.

```bash
cd webhook
chmod +x deploy.sh
./deploy.sh
```

For a first-time deploy (no existing stack), use the guided flow below instead.

```bash
# 1. Look up the VPC + subnets you'll use (the default VPC works fine)
aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text
aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id> \
    --query 'Subnets[].SubnetId' --output text

# 2. Build (uses Docker so psycopg2-binary gets the right arm64 wheel)
sam build --use-container

# 3. First deploy. Prompts ask for stack name, region, the VPC + subnet IDs
#    from step 1, the RDS master password (32+ chars, see below), an optional
#    non-default Postgres port, the GitHub webhook secret, a GitHub PAT for
#    the collector Lambdas, and the target repos/orgs/prefix.
sam deploy --guided

# Generate a strong DB password (paste this when prompted for DBPassword):
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
# Generate a webhook secret (paste this when prompted for WebhookSecret):
python3 -c "import secrets; print(secrets.token_urlsafe(24))"
```

When the deploy finishes, note these two stack outputs (the stack also
exports the collector Lambda names and the GitHub token secret ARN):

- `WebhookUrl` — paste into the GitHub webhook *Payload URL*
- `DatabaseEndpoint` — connection target (password is what you typed)

## Initialize the schema (one-time)

```bash
PGPASSWORD='<DBPassword>' psql \
    "<DatabaseEndpoint>" \
    -f ../db/schema.sql
```

## Configure the GitHub webhook

In *Repository settings* → *Webhooks* → *Add webhook* (or *Organization
settings* → *Webhooks* to cover every repo in the org — org deliveries land
in `events_webhook_org`, repo deliveries in `events_webhook_repo`):

- Payload URL: the `WebhookUrl` from `sam deploy`
- Content type: `application/json`
- Secret: the `WebhookSecret` you typed during `sam deploy`
- SSL verification: enabled
- Which events: *Send me everything* (you can narrow this later)

GitHub will fire a `ping` immediately. The handler answers `200 pong` and
does **not** write a row for it.

## Verify

```bash
PGPASSWORD='<DBPassword>' psql "<DatabaseEndpoint>" -c \
  "SELECT source, event_type, repo_name, actor_login, created_at
   FROM v_events_all
   WHERE source IN ('webhook_org', 'webhook_repo')
   ORDER BY created_at DESC LIMIT 10;"
```

Trigger an event (e.g. push a commit, open an issue) and re-run the query.

## Run analyzers against the webhook data

From the repo root, point the existing tooling at the same DB:

```bash
export DATABASE_URL='postgresql://<DBUsername>:<DBPassword>@<host>:<DBPort>/<DBName>'
python cli.py analyze
python cli.py report
```

## Tear down

```bash
sam delete
```

That removes the Lambdas (webhook receiver + scheduled collectors), Function
URL, schedules, GitHub token secret, RDS instance, subnet group, and
security group.

## Notes

- The receiver writes each delivery into `events_webhook_org` or
  `events_webhook_repo` (chosen by the `X-GitHub-Hook-Installation-Target-Type`
  header), while the polling collector writes to `events_api`. The streams
  stay in separate tables and are unioned with a `source` column
  (`webhook_org` / `webhook_repo` / `events_api` / `snapshot`) in
  `v_events_all`.
- Every delivery is also recorded in `webhook_deliveries` as an audit log,
  even when the event itself is skipped (e.g. no repo name).
- `id` is `X-GitHub-Delivery` (UUID) — no collision with the numeric IDs the
  polling collector uses, and `ON CONFLICT (id) DO NOTHING` makes redelivery
  idempotent.
- For `push` events, `payload.after` is also copied to `payload.head` so the
  analyzers that read `payload->>'head'` (see `collectors/commits.py`) work
  unchanged.
- Security group opens the chosen `DBPort` (default `54321`) to
  `0.0.0.0/0`. The non-default port reduces drive-by scanner noise but is
  not security against a targeted attacker — the 32-char random password is
  the actual barrier. Rotate the password and the webhook secret if the
  stack lives longer than a few weeks.
