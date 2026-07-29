-- id: oidc-risky-workflow-run
-- severity: high
-- description: OIDC-minting workflow '{workflow_path}' ran on untrusted trigger '{trigger}' (head_repo {head_repo}) in {repo_name}
-- tactic: Credential Access
-- actor: actor_login
-- event_id: {run_id}:{workflow_path}
-- evidence: workflow_path, trigger, head_branch, head_repo, commit_sha, run_started_at
-- repo_column: repo_name
--
-- Logic (workflow_runs x workflow_files):
--   A workflow run whose file (in workflow_files) requests id-token: write,
--   where the run fired on an untrusted, privileged-context trigger
--   (pull_request_target, workflow_run, issue_comment, PR review events) OR
--   the run's code came from a fork (head_repository differs from
--   repository). Such a run can mint an OIDC token from attacker-influenced
--   input executing in the base repo's context.
--
SELECT
    r.repo_name,
    r.id                                           AS run_id,
    r.workflow_path,
    r.event                                        AS trigger,
    r.head_branch,
    r.head_sha                                     AS commit_sha,
    r.payload->'head_repository'->>'full_name'     AS head_repo,
    r.actor_login,
    r.run_started_at
FROM workflow_runs r
JOIN workflow_files f
  ON f.repo_name = r.repo_name
 AND f.path      = r.workflow_path
WHERE f.content ILIKE '%%id-token: write%%'
  AND (
        r.event IN ('pull_request_target', 'workflow_run',
                    'issue_comment', 'pull_request_review', 'pull_request_review_comment')
     OR (r.payload->'head_repository'->>'full_name')
          IS DISTINCT FROM (r.payload->'repository'->>'full_name')
      )
