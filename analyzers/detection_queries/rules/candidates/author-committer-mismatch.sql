-- id: author-committer-mismatch
-- severity: low
-- description: Commit {sha:.12} has mismatched author ({author_name}<{author_email}>) vs committer ({committer_name}<{committer_email}>)
-- tactic: Defense Evasion
-- actor: actor_login
-- event_id: {sha}
-- evidence: sha, author_name, author_email, committer_name, committer_email, message_headline
-- candidate: true
--
-- Logic (push_commits):
--   Commit where both author and committer name+email differ (and neither
--   email is a GitHub noreply address). Typical of git commit --author
--   spoofing while someone else actually committed.
--
SELECT sha, repo_name,
       author_login, author_name, author_email,
       committer_login, committer_name, committer_email,
       COALESCE(committer_login, author_login) AS actor_login,
       message_headline
FROM push_commits
WHERE author_email IS NOT NULL
  AND committer_email IS NOT NULL
  AND author_email <> committer_email
  AND author_name IS NOT NULL
  AND committer_name IS NOT NULL
  AND author_name <> committer_name
  AND author_email NOT LIKE '%%@users.noreply.github.com'
  AND committer_email NOT LIKE '%%@users.noreply.github.com'
  AND author_email <> 'noreply@github.com'
  AND committer_email <> 'noreply@github.com'
