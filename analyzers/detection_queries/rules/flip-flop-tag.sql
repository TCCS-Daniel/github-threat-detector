-- id: flip-flop-tag
-- severity: critical
-- description: Tag '{tag_name}' moved away from {legit_sha:.12} and back ({states_in_between} state(s) in between) — flip-flop tag poisoning
-- tactic: Initial Access
-- event_id: {repo_name}:{tag}
-- evidence: tag, tag_name, legit_sha, states_in_between
-- source: reviewdog-01
--
-- Logic (webhook push history for a single tag):
--   Attack pattern: a floating tag is force-moved off a legitimate SHA onto a
--   different (often malicious) commit, then later force-moved back to the
--   original SHA to hide the window — clean -> poisoned -> clean (reviewdog).
--
--   seq  — per (repo, tag), the ordered list of `after` SHAs from tag PushEvents
--          (each force-repoint appends one entry).
--   flip — pairs of indices (i, j) in that list where shas[i] == shas[j], there
--          is at least one intervening index, and at least one intervening SHA
--          differs from shas[i] (so a no-op re-push of the same SHA is ignored).
--   out  — one finding per (repo, tag): the latest such flip (largest end_i),
--          reporting the returned-to SHA as legit_sha and how many states sat
--          between the leave and the return.
--
-- Sibling: flip-flop-tag-history (same signal via repo_tags_history snapshots).
WITH seq AS (
   SELECT payload->'repository'->>'full_name' AS repo_name,
          payload->>'ref' AS tag,
          array_agg(payload->>'after' ORDER BY created_at) AS shas
   FROM events_webhook_org
   WHERE event_type = 'PushEvent'
     AND payload->>'ref' LIKE 'refs/tags/%%'
   GROUP BY 1, 2
 ),
 flip AS (
   SELECT repo_name, tag, shas, i AS start_i, j AS end_i
   FROM seq
   CROSS JOIN LATERAL generate_subscripts(shas, 1) i
   CROSS JOIN LATERAL generate_subscripts(shas, 1) j
   WHERE j > i + 1
     AND shas[i] = shas[j]
     AND EXISTS (
       SELECT 1 FROM generate_subscripts(shas, 1) k
       WHERE k > i AND k < j AND shas[k] <> shas[i]
     )
 )
 SELECT DISTINCT ON (repo_name, tag)
        repo_name, tag,
        regexp_replace(tag, '^refs/tags/', '') AS tag_name,
        shas[start_i] AS legit_sha,
        (end_i - start_i - 1) AS states_in_between
 FROM flip
 ORDER BY repo_name, tag, end_i DESC
