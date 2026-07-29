-- id: author-differs-from-pusher
-- severity: low
-- description: Push by {pusher_display} claims author {author_claim} — author differs from pusher
-- tactic: Defense Evasion
-- actor: pusher
-- event_id: {id}
-- evidence: author_login, author_email, author_claim, commit_sha, created_at
-- repo_column: repo
-- source: megalodon-04
--
-- Logic (webhook PushEvent):
--   Flag pushes where the head commit's author username differs from the
--   pusher (actor_login). Signals identity spoofing via crafted author
--   metadata while someone else actually pushed.
--
SELECT id, repo_name,
       payload->'repository'->>'full_name'           AS repo,
       actor_login                                   AS pusher,
       COALESCE(actor_login, 'unknown')              AS pusher_display,
       payload->'head_commit'->'author'->>'username' AS author_login,
       payload->'head_commit'->'author'->>'email'    AS author_email,
       COALESCE(payload->'head_commit'->'author'->>'username',
                payload->'head_commit'->'author'->>'email',
                'unresolved')                        AS author_claim,
       COALESCE(payload->>'after', payload->'head_commit'->>'id') AS commit_sha,
       created_at
FROM events_webhook_org
WHERE event_type = 'PushEvent'
  AND COALESCE(payload->'head_commit'->'author'->>'username','') <> actor_login
