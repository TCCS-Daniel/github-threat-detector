-- id: symlink-traversal
-- severity: critical
-- description: Symlink '{symlink_path}' -> '{target}' ({reasons})
-- tactic: Execution
-- event_id: {repo_name}:{symlink_path}
-- evidence: symlink_path, target, reasons
-- data_source: git_forensics
-- candidate: true
--
-- Logic (git_repo_checks symlinks):
--   Expand result.symlinks; fire when the target hits ../.git, .git/hooks,
--   .git/config, .git/objects, or has >=3 ../ segments. Reasons column
--   lists which checks matched.
--
SELECT repo_name,
       s->>'path' AS symlink_path,
       s->>'target' AS target,
       concat_ws(', ',
         CASE WHEN s->>'target' LIKE '%%../.git%%' THEN 'targets ../.git' END,
         CASE WHEN s->>'target' LIKE '%%.git/hooks%%' THEN 'targets .git/hooks' END,
         CASE WHEN s->>'target' LIKE '%%.git/config%%' THEN 'targets .git/config' END,
         CASE WHEN s->>'target' LIKE '%%.git/objects%%' THEN 'targets .git/objects' END,
         CASE WHEN (length(s->>'target') - length(replace(s->>'target', '../', ''))) / 3 >= 3
              THEN 'deep directory traversal' END
       ) AS reasons
FROM git_repo_checks g
CROSS JOIN LATERAL jsonb_array_elements(g.result->'symlinks') AS s
WHERE g.check_type = 'symlinks'
  AND jsonb_typeof(g.result->'symlinks') = 'array'
  AND (
    s->>'target' LIKE '%%../.git%%'
    OR s->>'target' LIKE '%%.git/hooks%%'
    OR s->>'target' LIKE '%%.git/config%%'
    OR s->>'target' LIKE '%%.git/objects%%'
    OR (length(s->>'target') - length(replace(s->>'target', '../', ''))) / 3 >= 3
  )
