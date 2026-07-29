-- id: many-tags-same-commit
-- severity: low
-- description: {tag_count} tags pushed pointing to the same commit {commit_sha:.12}
-- tactic: Initial Access
-- event_id: {repo_name}:{commit_sha}
-- evidence: commit_sha, tag_count, tags
-- source: trivy-03
--
-- Logic (webhook PushEvent on tags):
--   Group tag pushes by (repo, after SHA). Fire when 2+ distinct tag refs
--   point at the same commit. Sibling to many-tags-same-commit-history.
--
SELECT repo_name,
       payload->>'after' AS commit_sha,
       count(DISTINCT payload->>'ref') AS tag_count,
       (array_agg(DISTINCT payload->>'ref'))[1:50] AS tags
FROM events_webhook_org
WHERE event_type = 'PushEvent'
  AND payload->>'ref' LIKE 'refs/tags/%%'
GROUP BY 1, 2
HAVING count(DISTINCT payload->>'ref') > 1
