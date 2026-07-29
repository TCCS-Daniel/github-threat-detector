-- id: unverified-commit-protected-ref
-- severity: medium
-- description: Unverified commit {sha:.12} on protected ref {ref} in a repo where {signed_pct}% of commits are signed
-- tactic: Defense Evasion
-- actor: author_login
-- event_id: {sha}
-- evidence: sha, ref, author_email, committer_date, verification_reason, signed_pct, signed_ratio
-- source: trivy-07
-- candidate: true
--
-- Logic (push_commits signing baseline):
--   signing — repos with >=5 commits that have verification data and >=80%%
--             verified=true.
--   out     — unverified commits on tags or main/master in those repos.
--             Anomaly: unsigned commit on a protected ref in a signing-heavy
--             repository.
--
WITH signing AS (
  SELECT repo_name,
         COUNT(*) FILTER (WHERE verified = true) AS signed,
         COUNT(*) AS total
  FROM push_commits
  WHERE verified IS NOT NULL
  GROUP BY repo_name
  HAVING COUNT(*) >= 5
     AND COUNT(*) FILTER (WHERE verified = true)::float / COUNT(*) >= 0.8
)
SELECT pc.repo_name, pc.ref, pc.sha, pc.author_login, pc.author_email,
       pc.committer_date, pc.verification_reason,
       s.signed, s.total,
       (s.signed::text || '/' || s.total::text) AS signed_ratio,
       ((s.signed * 100) / s.total) AS signed_pct
FROM push_commits pc
JOIN signing s ON s.repo_name = pc.repo_name
WHERE pc.verified IS NOT TRUE
  AND (pc.ref LIKE 'refs/tags/%%' OR pc.ref IN ('refs/heads/main', 'refs/heads/master'))
