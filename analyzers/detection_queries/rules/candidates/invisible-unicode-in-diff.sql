-- id: invisible-unicode-in-diff
-- severity: high
-- description: Commit {sha:.12} contains invisible Unicode characters in {file_count} file(s)
-- tactic: Defense Evasion
-- event_id: {repo_name}:{sha}
-- evidence: sha, files, file_count
-- data_source: git_forensics
-- candidate: true
--
-- Logic (git_repo_checks unicode_artifacts):
--   Expand result.commits; keep commits whose files array is non-empty
--   (invisible Unicode found in diffs). GlassWorm-style hidden payload signal.
--
SELECT repo_name,
       c->>'sha' AS sha,
       c->'files' AS files,
       jsonb_array_length(COALESCE(c->'files', '[]'::jsonb)) AS file_count
FROM git_repo_checks g
CROSS JOIN LATERAL jsonb_array_elements(g.result->'commits') AS c
WHERE g.check_type = 'unicode_artifacts'
  AND jsonb_typeof(g.result->'commits') = 'array'
  AND jsonb_array_length(COALESCE(c->'files', '[]'::jsonb)) > 0
