-- id: gitattributes-filter-abuse
-- severity: critical
-- description: .gitattributes contains {directive_count} non-LFS filter/smudge/clean directive(s) that execute commands on checkout/add
-- tactic: Execution
-- event_id: {repo_name}
-- evidence: directives, directive_count
-- data_source: git_forensics
-- candidate: true
--
-- Logic (git_repo_checks gitattributes):
--   Expand result.directives; keep non-LFS filter/smudge/clean commands.
--   Fire when any such directive exists — custom filters run on checkout/add
--   and can execute attacker-controlled code.
--
SELECT repo_name,
       jsonb_agg(d) AS directives,
       count(*) AS directive_count
FROM git_repo_checks g
CROSS JOIN LATERAL jsonb_array_elements(g.result->'directives') AS d
WHERE g.check_type = 'gitattributes'
  AND (g.result->>'exists')::boolean IS TRUE
  AND jsonb_typeof(g.result->'directives') = 'array'
  AND lower(COALESCE(d->>'command', '')) NOT IN ('lfs', 'git-lfs')
GROUP BY repo_name
HAVING count(*) > 0
