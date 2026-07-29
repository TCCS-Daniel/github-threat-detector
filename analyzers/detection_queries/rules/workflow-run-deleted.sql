-- id: workflow-run-deleted
-- severity: medium
-- description: Workflow run {run_id} ('{workflow_name}') completed but is {reason} in the runs API — run deleted to hide activity
-- tactic: Defense Evasion
-- actor: actor_login
-- event_id: {id}
-- evidence: run_id, workflow_name, workflow_path, head_branch, commit_sha, trigger, reason, created_at
-- source: bitwarden-03
--
-- Logic (WorkflowRunEvent completed x workflow_runs):
--   Completed workflow_run webhook whose run id is missing from workflow_runs,
--   marked status=deleted by the collector after a 404, or present with a null
--   conclusion — the run was deleted or wiped after completion to hide CI
--   activity (bitwarden-style cover-up).
--
SELECT e.id, e.repo_name, e.actor_login, e.created_at,
       e.payload#>>'{workflow_run,id}'          AS run_id,
       e.payload#>>'{workflow_run,name}'        AS workflow_name,
       e.payload#>>'{workflow_run,path}'        AS workflow_path,
       e.payload#>>'{workflow_run,head_branch}' AS head_branch,
       e.payload#>>'{workflow_run,head_sha}'    AS commit_sha,
       e.payload#>>'{workflow_run,event}'       AS trigger,
       CASE
         WHEN w.id IS NULL THEN 'absent'
         WHEN w.status = 'deleted' THEN 'deleted'
         ELSE 'null_conclusion'
       END AS reason
FROM events_webhook_org e
LEFT JOIN workflow_runs w
       ON w.id = e.payload#>>'{workflow_run,id}'
WHERE e.event_type = 'WorkflowRunEvent'
  AND e.payload->>'action' = 'completed'
  AND (w.id IS NULL OR w.status = 'deleted' OR w.conclusion IS NULL)
