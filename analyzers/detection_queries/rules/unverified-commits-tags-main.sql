-- id: unverified-commits-tags-main
-- severity: low
-- description: Unverified commit {sha:.12} on protected ref {ref}
-- tactic: Defense Evasion
-- actor: author_login
-- event_id: {sha}
-- evidence: sha, ref, author_email, committer_date, verification_reason
-- source: trivy-07
--
-- Logic (push_commits):
--   Unverified commits (verified IS NOT TRUE — false or null) on tag refs
--   or main/master. Unsigned commits landing on protected / release refs.
--
SELECT repo_name, ref, sha, author_login, author_email, committer_date, verification_reason
FROM push_commits
WHERE verified IS NOT TRUE
  AND (ref LIKE 'refs/tags/%%' OR ref IN ('refs/heads/main', 'refs/heads/master'))
