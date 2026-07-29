-- id: pr-instant-close
-- severity: high
-- description: Fork PR #{pr_number} by {actor_login} opened and closed within {close_seconds_int}s — automated workflow trigger exploit
-- tactic: Execution
-- actor: actor_login
-- event_id: {id}
-- evidence: pr_number, head_repo, close_seconds, created_at
-- candidate: true
--
-- Logic (v_events_all PullRequestEvent):
--   opens  — PRs with action=opened (capture fork flag + head repo).
--   closes — same actor/repo/number with action=closed.
--   Join open->close within 0–10 seconds on a fork PR — automated open/close
--   to fire untrusted workflows without leaving a lasting PR.
--
WITH opens AS (
  SELECT id, repo_name, actor_login, created_at,
         payload->>'number' AS pr_number,
         payload->'pull_request'->'head'->'repo'->>'fork' AS is_fork,
         payload->'pull_request'->'head'->'repo'->>'full_name' AS head_repo
  FROM v_events_all
  WHERE event_type = 'PullRequestEvent'
    AND payload->>'action' = 'opened'
),
closes AS (
  SELECT repo_name, actor_login, created_at,
         payload->>'number' AS pr_number
  FROM v_events_all
  WHERE event_type = 'PullRequestEvent'
    AND payload->>'action' = 'closed'
)
SELECT o.id, o.repo_name, o.actor_login, o.created_at,
       o.pr_number, o.head_repo,
       EXTRACT(EPOCH FROM (c.created_at - o.created_at)) AS close_seconds,
       EXTRACT(EPOCH FROM (c.created_at - o.created_at))::int AS close_seconds_int
FROM opens o
JOIN closes c
  ON o.repo_name = c.repo_name
 AND o.actor_login = c.actor_login
 AND o.pr_number = c.pr_number
 AND EXTRACT(EPOCH FROM (c.created_at - o.created_at)) BETWEEN 0 AND 10
WHERE o.is_fork = 'true'
