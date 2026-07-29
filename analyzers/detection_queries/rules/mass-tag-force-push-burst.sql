-- id: mass-tag-force-push-burst
-- severity: critical
-- description: {tags_rewritten} tags force-pushed within a 5-minute window — mass tag force-push burst
-- tactic: Impact
-- event_id: {repo_name}:{bucket}
-- evidence: bucket, tags_rewritten, tag_list, commit_sha
-- source: trivy-01
--
-- Logic (webhook PushEvent on tags):
--   Tag push that is not create/delete, before != zero SHA, and before !=
--   after (a real force-repoint). Bucket by 5-minute windows; fire when a
--   repo rewrites 5+ tags in one bucket. Sibling: mass-tag-force-push-history.
--
SELECT repo_name,
       date_bin('5 minutes', created_at, timestamptz '2000-01-01') AS bucket,
       count(*) AS tags_rewritten,
       (array_agg(DISTINCT regexp_replace(payload->>'ref', '^refs/tags/', '')
                  ORDER BY regexp_replace(payload->>'ref', '^refs/tags/', '')))[1:50] AS tag_list,
       (array_agg(DISTINCT payload->>'after'))[1] AS commit_sha
FROM events_webhook_org
WHERE event_type = 'PushEvent'
  AND payload->>'ref' LIKE 'refs/tags/%%'
  AND (payload->>'created')::bool = false
  AND (payload->>'deleted')::bool = false
  AND payload->>'before' <> %(zero)s
  AND payload->>'before' <> payload->>'after'
GROUP BY 1, 2
HAVING count(*) >= 5
