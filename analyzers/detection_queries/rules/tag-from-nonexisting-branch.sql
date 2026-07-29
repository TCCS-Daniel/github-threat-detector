-- id: tag-from-nonexisting-branch
-- severity: high
-- description: Tag '{tag}' resolves to a commit on no existing branch — tag from non-existing branch
-- tactic: Initial Access
-- event_id: {repo_name}:{tag}
-- evidence: tag, tag_name, commit_sha
-- data_source: git_forensics
-- source: tjactions-03
--
-- Logic (git_repo_checks tag_provenance):
--   Expand result.tags from forensics; each entry is a tag whose commit is
--   reachable from no current branch. Requires branches_found > 0 so empty/
--   failed clones do not false-positive. Off-branch tag commits (tj-actions).
--
SELECT repo_name,
       t->>'tag_name' AS tag,
       t->>'tag_name' AS tag_name,
       t->>'commit_sha' AS commit_sha
FROM git_repo_checks
CROSS JOIN LATERAL jsonb_array_elements(result->'tags') AS t
WHERE check_type = 'tag_provenance'
  AND jsonb_array_length(result->'tags') > 0
  AND (result->>'branches_found')::int > 0
