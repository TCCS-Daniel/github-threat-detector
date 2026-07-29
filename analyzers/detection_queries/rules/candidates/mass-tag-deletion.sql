-- id: mass-tag-deletion
-- severity: medium
-- description: {del_count} tags deleted by {actor_display} within {window_minutes} minutes — mass tag purge
-- tactic: Defense Evasion
-- actor: actor_login
-- event_id: {repo_name}:{actor_login}:{day_bucket}
-- evidence: del_count, first_at, last_at, window_minutes, tags
--
-- Logic (repo_activities branch_deletion on tag refs):
--   Per (repo, actor, calendar day), count tag deletions. Fire when 5+ tags
--   are deleted by the same actor and the span from first to last is <= 60
--   minutes — mass tag purge / cleanup cover for prior poisoning.
--
SELECT repo_name,
       actor_login,
       COALESCE(actor_login, 'unknown') AS actor_display,
       count(*) AS del_count,
       min(timestamp) AS first_at,
       max(timestamp) AS last_at,
       date_trunc('day', timestamp) AS day_bucket,
       round(EXTRACT(EPOCH FROM (max(timestamp) - min(timestamp))) / 60.0, 1) AS window_minutes,
       (array_agg(regexp_replace(ref, '^refs/tags/', '') ORDER BY timestamp))[1:50] AS tags
FROM repo_activities
WHERE activity_type = 'branch_deletion'
  AND ref LIKE 'refs/tags/%%'
GROUP BY repo_name, actor_login, date_trunc('day', timestamp)
HAVING count(*) >= 5
   AND EXTRACT(EPOCH FROM (max(timestamp) - min(timestamp))) <= 60 * 60
