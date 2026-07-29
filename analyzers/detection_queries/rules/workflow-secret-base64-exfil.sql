-- id: workflow-secret-base64-exfil
-- severity: critical
-- description: Workflow '{path}' on {ref} echoes secrets through base64 — log exfiltration pattern
-- tactic: Exfiltration
-- event_id: {repo_name}:{ref}:{path}
-- evidence: path, ref, fetched_at
-- source: bitwarden-02
--
-- Logic (workflow_files content regex):
--   Workflow body that pipes token/secret/password/key material through
--   echo/printf/cat/tee/print into base64, or double-base64 encodes — classic
--   Actions log exfiltration pattern.
--
SELECT repo_name, path, fetched_at, ref
FROM workflow_files
WHERE (content ~* '(echo|printf|cat|tee|print)[^\n]*(token|secret|password|key|npm_token|oidc)[^\n]*\|\s*base64'
       OR content ~* 'base64\s*(-w ?0\s*)?\|\s*base64')
