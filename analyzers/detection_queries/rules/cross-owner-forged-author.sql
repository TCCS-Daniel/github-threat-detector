-- id: cross-owner-forged-author
-- severity: high
-- description: Forged author email {author_email} appears across {owners} owners / {repos} repos — cross-owner forged-author campaign
-- tactic: Defense Evasion
-- actor: author_email
-- event_id: {author_email}
-- evidence: author_email, owners, repos, owner_list, first_seen, last_seen
-- repo_column: source_repo
-- data_source: author_enrichment
-- source: megalodon-05
--
-- Logic (commit_author_search enrichment, last 24h):
--   Group enrichment hits by author_email. Fire when the same email appears
--   under 2+ distinct owners — a forged identity reused across unrelated
--   orgs/repos (campaign signal). Uses min(source_repo) as the finding repo.
--
SELECT author_email,
       count(DISTINCT owner)          AS owners,
       count(DISTINCT repo_full_name) AS repos,
       array_agg(DISTINCT owner)      AS owner_list,
       min(source_repo)               AS source_repo,
       min(found_at)                  AS first_seen,
       max(found_at)                  AS last_seen
FROM commit_author_search
WHERE found_at > now() - interval '24 hours'
GROUP BY author_email
HAVING count(DISTINCT owner) >= 2
