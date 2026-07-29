-- id: many-tags-same-commit-history
-- severity: low
-- description: {tags} tags moved to the same commit {commit_sha:.12} — coordinated tag repointing
-- tactic: Initial Access
-- event_id: {repo_name}:{commit_sha}
-- evidence: commit_sha, tags, tag_list
-- source: tjactions-02
--
-- Logic (repo_tags_history):
--   Count distinct tags that were rewritten onto the same new_sha (old_sha
--   must differ). Fire at 3+ tags sharing one target commit — coordinated
--   multi-tag repointing. Sibling to many-tags-same-commit (webhook).
--
SELECT repo_name,
       new_sha AS commit_sha,
       count(DISTINCT tag_name) AS tags,
       (array_agg(DISTINCT tag_name ORDER BY tag_name))[1:50] AS tag_list
FROM repo_tags_history
WHERE old_sha <> new_sha
GROUP BY 1, 2
HAVING count(DISTINCT tag_name) >= 3
