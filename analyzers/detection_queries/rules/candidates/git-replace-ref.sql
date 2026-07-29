-- id: git-replace-ref
-- severity: critical
-- description: Repository has {ref_count} git replace ref(s) — commit objects are being silently substituted
-- tactic: Defense Evasion
-- event_id: {repo_name}
-- evidence: replace_refs, ref_count
-- data_source: git_forensics
-- candidate: true
--
-- Logic (git_repo_checks replace_refs):
--   Forensics found one or more refs/replace/* entries. Those silently
--   substitute commit objects on fetch/checkout — integrity bypass.
--
SELECT repo_name,
       result->'refs' AS replace_refs,
       jsonb_array_length(result->'refs') AS ref_count
FROM git_repo_checks
WHERE check_type = 'replace_refs'
  AND jsonb_typeof(result->'refs') = 'array'
  AND jsonb_array_length(result->'refs') > 0
