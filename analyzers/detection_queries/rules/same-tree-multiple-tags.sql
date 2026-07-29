-- id: same-tree-multiple-tags
-- severity: low
-- description: {tag_count} tags point at commits sharing the same tree {tree_id:.12} — duplicated tag content
-- tactic: Initial Access
-- event_id: {repo_name}:{tree_id}
-- evidence: tree_id, tag_count, tag_list
-- source: trivy-02
--
-- Logic (webhook PushEvent on tags):
--   Group by (repo, head_commit.tree_id). Fire when 3+ distinct tag refs
--   share the same tree — duplicated tag content / cloned release trees
--   (often alongside fabricated tag commits).
--
SELECT repo_name,
       payload->'head_commit'->>'tree_id' AS tree_id,
       count(DISTINCT payload->>'ref') AS tag_count,
       (array_agg(DISTINCT regexp_replace(payload->>'ref', '^refs/tags/', '')
                  ORDER BY regexp_replace(payload->>'ref', '^refs/tags/', '')))[1:50] AS tag_list
FROM events_webhook_org
WHERE event_type = 'PushEvent'
  AND payload->>'ref' LIKE 'refs/tags/%%'
  AND payload->'head_commit'->>'tree_id' IS NOT NULL
GROUP BY 1, 2
HAVING count(DISTINCT payload->>'ref') >= 3
