-- id: tag-committer-differs-from-pusher
-- severity: low
-- description: Tag '{tag_name}' pushed by {pusher_display} with committer {committer_name}<{committer_email}> — committer differs from pusher
-- tactic: Defense Evasion
-- actor: pusher
-- event_id: {id}
-- evidence: tag_ref, tag_name, commit_sha, committer_name, committer_email, created_at
-- source: trivy-04
--
-- Logic (webhook PushEvent on tags):
--   Tag push where lower(head_commit.committer.name) differs from
--   lower(pusher.name). Weak identity signal that the person who pushed is
--   not the recorded committer on the tagged commit.
--
SELECT id, created_at, repo_name,
       payload->>'ref' AS tag_ref,
       regexp_replace(payload->>'ref', '^refs/tags/', '') AS tag_name,
       COALESCE(payload->>'after', payload->'head_commit'->>'id') AS commit_sha,
       payload->'head_commit'->'committer'->>'name'  AS committer_name,
       payload->'head_commit'->'committer'->>'email' AS committer_email,
       payload->'pusher'->>'name'                    AS pusher,
       COALESCE(payload->'pusher'->>'name', 'unknown') AS pusher_display
FROM events_webhook_org
WHERE event_type = 'PushEvent'
  AND payload->>'ref' LIKE 'refs/tags/%%'
  AND lower(payload->'head_commit'->'committer'->>'name')
      <> lower(payload->'pusher'->>'name')
