-- id: ghost-committer
-- severity: medium
-- description: Commit {sha:.12} by committer {committer_display} does not resolve to any GitHub account
-- tactic: Defense Evasion
-- actor: author_login
-- event_id: {sha}
-- evidence: sha, committer_name, committer_email, committer_date, message_headline
-- candidate: true
--
-- Logic (push_commits):
--   Committer email present but committer_login is null (GitHub could not
--   resolve the committer), excluding noreply@github.com and
--   *@users.noreply.github.com. Ghost / non-account committer identity.
--
SELECT sha, repo_name, author_login,
       committer_name, committer_email, committer_date, message_headline,
       COALESCE(committer_name, 'unknown') || '<' || committer_email || '>' AS committer_display
FROM push_commits
WHERE committer_login IS NULL
  AND committer_email IS NOT NULL
  AND committer_email <> ''
  AND committer_email <> 'noreply@github.com'
  AND committer_email NOT LIKE '%%@users.noreply.github.com'
