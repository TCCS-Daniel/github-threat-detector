-- id: oidc-workflow-push-default
-- severity: medium
-- description: OIDC-granting workflow '{path}' pushed directly to default branch by {pusher_display}
-- tactic: Credential Access
-- actor: pusher
-- event_id: {id}:{path}
-- evidence: path, ref, commit_sha, created_at
-- repo_column: repo
-- source: megalodon-02
--
-- Logic (webhook PushEvent x workflow_files):
--   Default-branch push whose commits touch a workflow path that (in
--   workflow_files) contains id-token: write. OIDC-granting workflow landed
--   directly on default without going through a non-default path.
--
SELECT e.id, e.repo_name,
       e.payload->'repository'->>'full_name' AS repo,
       f.path,
       e.payload->>'ref'                     AS ref,
       COALESCE(e.payload->>'after', e.payload->'head_commit'->>'id') AS commit_sha,
       e.actor_login                         AS pusher,
       COALESCE(e.actor_login, 'unknown')    AS pusher_display,
       e.created_at
FROM events_webhook_org e
JOIN workflow_files f
  ON  f.repo_name = e.payload->'repository'->>'full_name'
  AND f.ref = e.payload->>'ref'
  AND f.content ILIKE '%%id-token: write%%'
WHERE e.event_type = 'PushEvent'
  AND e.payload->>'ref' = 'refs/heads/' || (e.payload->'repository'->>'default_branch')
  AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(e.payload->'commits') c
    CROSS JOIN LATERAL (
      SELECT jsonb_array_elements_text(c->'added')
      UNION ALL
      SELECT jsonb_array_elements_text(c->'modified')
    ) fp(path)
    WHERE fp.path = f.path
  )
