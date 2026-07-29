-- id: tag-parent-commit-future
-- severity: critical
-- description: Tag commit {sha:.12} on {ref} was committed before its parent {parent_sha:.12} — impossible lineage
-- tactic: Defense Evasion
-- event_id: {sha}:{parent_sha}
-- evidence: sha, ref, parent_sha, committer_date, parent_committer_date, lineage_gap, message_headline
-- source: trivy-05
--
-- Logic (push_commits for tag refs):
--   Join each tag commit to its parent(s) in push_commits. Fire when the
--   child's committer_date is strictly before the parent's — impossible
--   natural lineage (clock skew / fabricated history).
--
SELECT c.repo_name, c.ref, c.sha, c.message_headline,
       c.committer_date,
       p.sha            AS parent_sha,
       p.committer_date AS parent_committer_date,
       (p.committer_date - c.committer_date) AS lineage_gap
FROM push_commits c
CROSS JOIN LATERAL unnest(c.parents) AS pe(parent_sha)
JOIN push_commits p
     ON p.repo_name = c.repo_name
    AND p.sha       = pe.parent_sha
WHERE c.ref LIKE 'refs/tags/%%'
  AND p.committer_date IS NOT NULL
  AND c.committer_date < p.committer_date
