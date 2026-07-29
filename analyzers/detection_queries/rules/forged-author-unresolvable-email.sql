-- id: forged-author-unresolvable-email
-- severity: low
-- description: Push by {pusher_display} with commit author {author_name}<{author_email}> that resolves to no GitHub account — forged author
-- tactic: Defense Evasion
-- actor: pusher
-- event_id: {id}
-- evidence: author_name, author_email, commit_sha, created_at
-- repo_column: repo
-- source: megalodon-03
--
-- Logic (webhook PushEvent):
--   Head commit has an author email but no author username field — GitHub
--   could not map the email to an account. Typical of forged/spoofed author
--   identity on an otherwise successful push.
--
SELECT id, repo_name,
       payload->'repository'->>'full_name'        AS repo,
       payload->'head_commit'->'author'->>'name'  AS author_name,
       payload->'head_commit'->'author'->>'email' AS author_email,
       actor_login                                AS pusher,
       COALESCE(actor_login, 'unknown')           AS pusher_display,
       COALESCE(payload->>'after', payload->'head_commit'->>'id') AS commit_sha,
       created_at
FROM events_webhook_org
WHERE event_type = 'PushEvent'
  AND payload->'head_commit'->'author'->>'email' IS NOT NULL
  AND NOT (payload->'head_commit'->'author' ? 'username')
