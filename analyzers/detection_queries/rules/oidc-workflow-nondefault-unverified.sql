-- id: oidc-workflow-nondefault-unverified
-- severity: medium
-- description: Workflow '{path}' granting OIDC token pushed to non-default ref {ref} via unverified commit {commit_sha:.12}
-- tactic: Credential Access
-- event_id: {commit_sha}:{path}
-- evidence: path, ref, commit_sha, verified, author_email, committer_date
-- source: bitwarden-01
--
-- Logic (workflow_files x push_commits):
--   Workflow under .github/workflows/ whose content requests id-token: write,
--   on a non-main/master ref, joined to an unverified commit on that same
--   ref. OIDC-capable workflow introduced off default via unverified push.
--
SELECT w.repo_name, w.ref, w.path,
       pc.sha AS commit_sha,
       pc.verified,
       pc.author_email,
       pc.committer_date
FROM workflow_files w
JOIN push_commits pc
      ON  pc.repo_name = w.repo_name
      AND pc.ref       = w.ref
WHERE w.path LIKE '.github/workflows/%%'
  AND w.content ILIKE '%%id-token: write%%'
  AND w.ref NOT IN ('refs/heads/main', 'refs/heads/master')
  AND pc.verified IS NOT TRUE
