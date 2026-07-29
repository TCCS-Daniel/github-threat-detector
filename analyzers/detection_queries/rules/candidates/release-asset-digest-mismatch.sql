-- id: release-asset-digest-mismatch
-- severity: high
-- description: Release {tag_name} asset '{asset_name}' digest changed from {previous_digest} to {current_digest} — post-publish artifact replacement
-- tactic: Impact
-- actor: actor_login
-- event_id: {id}:{asset_name}
-- evidence: tag_name, release_id, asset_name, previous_digest, current_digest, previous_event_at, current_event_at
-- candidate: true
--
-- Logic (ReleaseEvent assets across events):
--   assets — unnest release.assets with a non-null digest from each ReleaseEvent.
--   paired — same repo + release_id + asset_name where a later event shows a
--            different digest than an earlier one (clobber / re-upload).
--   out    — latest digest change per asset (GitHub digests are per-upload;
--            a change means the bytes behind that filename were replaced).
--
WITH assets AS (
  SELECT e.id,
         e.repo_name,
         e.actor_login,
         e.created_at,
         e.payload->'release'->>'id'       AS release_id,
         e.payload->'release'->>'tag_name' AS tag_name,
         a->>'name'                        AS asset_name,
         a->>'digest'                      AS digest
  FROM events_webhook_org e
  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(e.payload->'release'->'assets', '[]'::jsonb)
  ) AS a
  WHERE e.event_type = 'ReleaseEvent'
    AND jsonb_typeof(e.payload->'release'->'assets') = 'array'
    AND a->>'name' IS NOT NULL
    AND a->>'digest' IS NOT NULL
    AND a->>'digest' <> ''
    AND a->>'digest' <> 'null'
),
paired AS (
  SELECT later.id,
         later.repo_name,
         later.actor_login,
         later.tag_name,
         later.release_id,
         later.asset_name,
         earlier.digest     AS previous_digest,
         later.digest       AS current_digest,
         earlier.created_at AS previous_event_at,
         later.created_at   AS current_event_at
  FROM assets earlier
  JOIN assets later
    ON earlier.repo_name = later.repo_name
   AND earlier.release_id = later.release_id
   AND earlier.asset_name = later.asset_name
   AND later.created_at > earlier.created_at
   AND earlier.digest IS DISTINCT FROM later.digest
)
SELECT DISTINCT ON (repo_name, release_id, asset_name)
       id,
       repo_name,
       actor_login,
       tag_name,
       release_id,
       asset_name,
       previous_digest,
       current_digest,
       previous_event_at,
       current_event_at
FROM paired
ORDER BY repo_name, release_id, asset_name, current_event_at DESC
