-- id: mass-tag-force-push-history
-- severity: critical
-- description: {tags_rewritten} tags rewritten within a 5-minute window — mass tag force-push burst (tag history)
-- tactic: Impact
-- event_id: {repo_name}:{bucket}
-- evidence: bucket, tags_rewritten, tag_list, commit_sha
-- source: tjactions-01
--
-- Logic (repo_tags_history):
--   Tag rewrites where old_sha is present, non-zero, and differs from
--   new_sha. Bucket by 5-minute detected_at windows; fire at 5+ rewrites
--   per repo/bucket. Sibling to mass-tag-force-push-burst (webhook).
--
SELECT repo_name,
       date_bin('5 minutes', detected_at, timestamptz '2000-01-01') AS bucket,
       count(*) AS tags_rewritten,
       (array_agg(DISTINCT tag_name ORDER BY tag_name))[1:50] AS tag_list,
       (array_agg(DISTINCT new_sha))[1] AS commit_sha
FROM repo_tags_history
WHERE old_sha IS NOT NULL
  AND old_sha <> new_sha
  AND old_sha <> %(zero)s
GROUP BY 1, 2
HAVING count(*) >= 5
