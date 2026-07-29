-- id: direct-workflow-push-default
-- severity: low
-- description: Workflow file pushed directly to default branch {ref} by {pusher_display}
-- tactic: Execution
-- actor: pusher
-- event_id: {id}
-- evidence: path, ref, commit_sha, created_at
-- repo_column: repo
-- source: megalodon-01
--
-- Logic (webhook PushEvent):
--   Push landed on the repo default branch and at least one commit in the
--   payload added/modified a path under .github/workflows/. Direct workflow
--   edits on default skip PR review.
--
SELECT id, repo_name,
       payload->'repository'->>'full_name' AS repo,
       payload->>'ref'                     AS ref,
       actor_login                         AS pusher,
       COALESCE(actor_login, 'unknown')    AS pusher_display,
       COALESCE(payload->>'after', payload->'head_commit'->>'id') AS commit_sha,
       (
         SELECT fp.path
         FROM jsonb_array_elements(payload->'commits') c
         CROSS JOIN LATERAL (
           SELECT jsonb_array_elements_text(c->'added')
           UNION ALL
           SELECT jsonb_array_elements_text(c->'modified')
         ) fp(path)
         WHERE fp.path LIKE '.github/workflows/%%'
         LIMIT 1
       ) AS path,
       created_at
FROM events_webhook_org
WHERE event_type = 'PushEvent'
  AND payload->>'ref' = 'refs/heads/' || (payload->'repository'->>'default_branch')
  AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(payload->'commits') c
    CROSS JOIN LATERAL (
      SELECT jsonb_array_elements_text(c->'added')
      UNION ALL
      SELECT jsonb_array_elements_text(c->'modified')
    ) f(path)
    WHERE f.path LIKE '.github/workflows/%%'
  )
