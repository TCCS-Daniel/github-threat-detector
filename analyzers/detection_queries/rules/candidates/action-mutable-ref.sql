-- id: action-mutable-ref
-- severity: low
-- description: Workflow {workflow_path} pins {total_count} third-party action(s) to mutable tags instead of SHA hashes
-- tactic: Initial Access
-- event_id: {repo_name}:{workflow_path}
-- evidence: workflow_path, mutable_actions, total_count
-- candidate: true
--
-- Logic (workflow_files uses: lines):
--   Extract third-party owner/repo@vN… action pins (exclude actions/ and
--   github/). Fire per workflow that has any mutable tag pin instead of a
--   full SHA — tag-poisoning / floating-action risk.
--
WITH matches AS (
  SELECT w.repo_name,
         w.path,
         m[1] || '@' || m[2] AS action_ref
  FROM workflow_files w
  CROSS JOIN LATERAL regexp_matches(
    COALESCE(w.content, ''),
    'uses:\s+([\w.-]+/[\w.-]+)@(v\d[\w.-]*)',
    'gi'
  ) AS m
  WHERE m[1] !~* '^(actions|github)/'
)
SELECT repo_name,
       path AS workflow_path,
       count(*) AS total_count,
       (array_agg(action_ref ORDER BY action_ref))[1:10] AS mutable_actions
FROM matches
GROUP BY repo_name, path
HAVING count(*) > 0
