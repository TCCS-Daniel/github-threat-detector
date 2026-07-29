# Detection query rules

Each `.sql` file in `rules/` (and `rules/candidates/`) is one detection rule. A generic runner
(`runner.py`) executes the query, applies repo scoping, and writes a row into
`findings` for every result — so adding a rule is just SQL plus a small header,
no Python.

## Adding a rule

Drop a new `rules/<rule-id>.sql` file (or `rules/candidates/<rule-id>.sql` for
candidate / staged rules):

```sql
-- id: my-rule-id
-- severity: critical
-- description: Human sentence with {column} placeholders, e.g. commit {sha:.12}
-- event_id: {sha}:{path}
-- actor: pusher
-- evidence: path, ref, sha
-- source: acme-01
-- candidate: true
SELECT repo_name, path, ref, sha, actor_login AS pusher
FROM ...
WHERE ...
```

### Header fields

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | `rule_id` written to `findings` |
| `severity` | yes | `critical` / `high` / `medium` / `low` |
| `description` | yes | Template rendered per row (see below) |
| `event_id` | no | Template for the dedup key; omit to dedup on `(rule, repo, actor)` |
| `actor` | no | Column whose value becomes `actor_login` |
| `evidence` | no | Comma-separated columns stored as the JSON `evidence` |
| `repo_column` | no | Column holding the repo name (default `repo_name`) |
| `source` | no | Free-form provenance tag |
| `data_source` | no | Routes the rule to a specific Lambda. `git_forensics` -> `GitForensicsCollector` (reads `git_repo_checks`); `author_enrichment` -> `AuthorEnrichmentCollector` (reads `commit_author_search`); unset -> `SnapshotCollector` (default) |
| `candidate` | no | When `true`, findings are written with `is_candidate=true`. Rules under `rules/candidates/` are treated as candidates even without this header |

### Templates

`description` and `event_id` are rendered with Python `str.format`, so any
column returned by the query is available as `{column}`. `NULL` renders as an
empty string. Format specs work too — `{sha:.12}` prints the first 12
characters.

Do all display shaping in SQL (`COALESCE(pusher,'unknown')`,
`regexp_replace(ref,'^refs/tags/','')`, …) and reference the resulting column.

## Contract the runner relies on

- The query **must** return the repo column named by `repo_column`
  (default `repo_name`). The runner wraps the query as
  `SELECT * FROM (<your query>) _q WHERE %(repo)s IS NULL OR _q.<repo_column> = %(repo)s`,
  so repo filtering is automatic — never add it yourself.
- The query always runs with named params `%(repo)s` and `%(zero)s` bound
  (`%(zero)s` is the 40-zero SHA). Because params are bound, **literal `%`
  must be escaped as `%%`** (e.g. `LIKE 'refs/tags/%%'`).
- Do not end the file with a trailing `;`.
