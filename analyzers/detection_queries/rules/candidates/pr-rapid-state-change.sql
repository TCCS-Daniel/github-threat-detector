-- id: pr-rapid-state-change
-- severity: medium
-- description: PR #{pr_number} by {actor_login} had {state_changes} state changes in {window_seconds}s ({actions_display}) — workflow trigger probing
-- tactic: Execution
-- actor: actor_login
-- event_id: {repo_name}:{actor_login}:{pr_number}
-- evidence: pr_number, state_changes, actions, first_at, last_at, window_seconds
-- candidate: true
--
-- Logic (v_events_all PullRequestEvent):
--   Per (repo, actor, PR number), count opened/closed/reopened actions.
--   Fire when 3+ state changes occur within 300 seconds — workflow trigger
--   probing / rapid toggle abuse.
--
SELECT repo_name,
       actor_login,
       payload->>'number' AS pr_number,
       COUNT(*) AS state_changes,
       MIN(created_at) AS first_at,
       MAX(created_at) AS last_at,
       array_agg(payload->>'action' ORDER BY created_at) AS actions,
       array_to_string(array_agg(payload->>'action' ORDER BY created_at), ' -> ') AS actions_display,
       EXTRACT(EPOCH FROM (MAX(created_at) - MIN(created_at)))::int AS window_seconds
FROM v_events_all
WHERE event_type = 'PullRequestEvent'
  AND payload->>'action' IN ('opened', 'closed', 'reopened')
GROUP BY repo_name, actor_login, payload->>'number'
HAVING COUNT(*) >= 3
   AND EXTRACT(EPOCH FROM (MAX(created_at) - MIN(created_at))) <= 300
