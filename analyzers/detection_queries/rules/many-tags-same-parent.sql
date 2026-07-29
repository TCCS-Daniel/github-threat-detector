-- id: many-tags-same-parent
-- severity: medium
-- description: {tag_count} tag refs share the same parent commit {parent_sha:.12} — fabricated tag commits
-- tactic: Defense Evasion
-- event_id: {repo_name}:{parent_sha}
-- evidence: parent_sha, tag_count, tags
-- source: trivy-06
--
-- Logic (push_commits for tag refs):
--   Unnest each tag commit's parents and group by (repo, parent_sha). Fire
--   when 2+ distinct tag refs share the same parent — often fabricated
--   per-tag commits forked from one base (trivy-style).
--
SELECT c.repo_name,
       pe.parent_sha,
       count(DISTINCT c.ref)                    AS tag_count,
       (array_agg(DISTINCT c.ref ORDER BY c.ref))[1:50] AS tags
FROM push_commits c
CROSS JOIN LATERAL unnest(c.parents) AS pe(parent_sha)
WHERE c.ref LIKE 'refs/tags/%%'
GROUP BY c.repo_name, pe.parent_sha
HAVING count(DISTINCT c.ref) > 1
