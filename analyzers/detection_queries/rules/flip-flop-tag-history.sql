-- id: flip-flop-tag-history
-- severity: critical
-- description: Tag '{tag_name}' moved from {legit_sha:.12} to {poisoned_sha:.12} and later back — flip-flop tag poisoning (tag history)
-- tactic: Initial Access
-- event_id: {a_id}:{b_id}
-- evidence: tag_name, legit_sha, poisoned_sha
-- source: reviewdog-02
--
-- Logic (repo_tags_history snapshots):
--   Self-join tag-move rows a -> b on the same (repo, tag) where a's old_sha
--   equals b's new_sha and b is later — i.e. the tag left a SHA and later
--   returned to it (clean -> poisoned -> clean). Sibling to flip-flop-tag
--   (same signal from webhook push `after` sequences).
--
SELECT a.id AS a_id, b.id AS b_id,
       a.repo_name, a.tag_name,
       a.old_sha AS legit_sha,
       a.new_sha AS poisoned_sha
FROM repo_tags_history a
JOIN repo_tags_history b
  ON a.repo_name = b.repo_name
 AND a.tag_name  = b.tag_name
 AND a.old_sha   = b.new_sha
 AND b.detected_at > a.detected_at
