-- id: risky-workflow-pwn-request
-- severity: medium
-- description: Workflow '{path}' is pwn-request risky (risk score {risk}): untrusted trigger combined with attacker-controlled checkout/input
-- tactic: Execution
-- event_id: {repo_name}:{path}
-- evidence: path, risk, untrusted, checks_out_head, untrusted_interpolation, oidc_write, token_write, uses_cache, cross_run_artifact
-- source: tanstack-01
--
-- Logic (latest workflow_files content per path):
--   latest — newest row per (repo, path).
--   flags — regex features: untrusted triggers (pull_request_target,
--           issue_comment, review events, workflow_run), PR head checkout,
--           untrusted ${{ github.event.* }} interpolation, write perms,
--           cache, cross-run artifact download.
--   out   — require an untrusted/workflow_run trigger AND at least one
--           attacker-input vector (head checkout, interpolation, cache, or
--           cross-run artifact); emit a weighted risk score.
--
WITH latest AS (
  SELECT DISTINCT ON (repo_name, path) repo_name, path, content, ref, fetched_at
  FROM workflow_files
  ORDER BY repo_name, path, fetched_at DESC
),
flags AS (
  SELECT repo_name, path, ref, fetched_at,
    (content ~* '(^|\n)\s*on:.*pull_request_target'
      OR content ~* '(^|\n)\s*pull_request_target\s*:'
      OR content ~* '(^|\n)\s*issue_comment\s*:'
      OR content ~* '(^|\n)\s*(pull_request_review|pull_request_review_comment)\s*:'
    ) AS untrusted_trigger,
    (content ~* '(^|\n)\s*workflow_run\s*:') AS workflow_run_trigger,
    (content ~* 'refs/pull/[^/\n]*/(merge|head)'
      OR content ~* 'github\.event\.pull_request\.head'
      OR content ~* 'github\.head_ref'
    ) AS checks_out_head,
    (content ~* '\$\{\{\s*github\.event\.(pull_request\.(title|body|head_ref)|issue\.(title|body)|comment\.body|review\.body)\s*\}\}'
    ) AS untrusted_interpolation,
    (content ~* 'id-token:\s*write') AS oidc_write,
    (content ~* '(contents|packages|pull-requests|deployments|issues|actions|checks|statuses|security-events):\s*write') AS token_write,
    (content ~* 'actions/cache') AS uses_cache,
    (content ~* 'download-artifact' AND content ~* '(run[_-]id|workflow_run\.id|artifacts_url)') AS cross_run_artifact
  FROM latest
)
SELECT repo_name, path,
  (untrusted_trigger OR workflow_run_trigger) AS untrusted,
  checks_out_head, untrusted_interpolation,
  oidc_write, token_write, uses_cache, cross_run_artifact,
  ( untrusted_trigger::int*3 + workflow_run_trigger::int*1
    + checks_out_head::int*3 + untrusted_interpolation::int*3
    + oidc_write::int*1 + token_write::int*1
    + uses_cache::int*1 + cross_run_artifact::int*2 ) AS risk
FROM flags
WHERE (untrusted_trigger OR workflow_run_trigger)
  AND (checks_out_head OR untrusted_interpolation OR uses_cache OR cross_run_artifact)
