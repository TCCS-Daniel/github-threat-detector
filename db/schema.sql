CREATE TABLE IF NOT EXISTS events_webhook_org (
    id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    actor_login TEXT,
    actor_id BIGINT,
    repo_name TEXT NOT NULL,
    org_login TEXT,
    payload JSONB,
    created_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_events_webhook_org_repo ON events_webhook_org(repo_name);
CREATE INDEX IF NOT EXISTS idx_events_webhook_org_type ON events_webhook_org(event_type);
CREATE INDEX IF NOT EXISTS idx_events_webhook_org_actor ON events_webhook_org(actor_login);
CREATE INDEX IF NOT EXISTS idx_events_webhook_org_created ON events_webhook_org(created_at);

CREATE TABLE IF NOT EXISTS events_webhook_repo (
    id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    actor_login TEXT,
    actor_id BIGINT,
    repo_name TEXT NOT NULL,
    org_login TEXT,
    payload JSONB,
    created_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_events_webhook_repo_repo ON events_webhook_repo(repo_name);
CREATE INDEX IF NOT EXISTS idx_events_webhook_repo_type ON events_webhook_repo(event_type);
CREATE INDEX IF NOT EXISTS idx_events_webhook_repo_actor ON events_webhook_repo(actor_login);
CREATE INDEX IF NOT EXISTS idx_events_webhook_repo_created ON events_webhook_repo(created_at);

CREATE TABLE IF NOT EXISTS events_api (
    id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    actor_login TEXT,
    actor_id BIGINT,
    repo_name TEXT NOT NULL,
    org_login TEXT,
    payload JSONB,
    created_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_events_api_repo ON events_api(repo_name);
CREATE INDEX IF NOT EXISTS idx_events_api_type ON events_api(event_type);
CREATE INDEX IF NOT EXISTS idx_events_api_actor ON events_api(actor_login);
CREATE INDEX IF NOT EXISTS idx_events_api_created ON events_api(created_at);

CREATE TABLE IF NOT EXISTS events_snapshot (
    id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    actor_login TEXT,
    actor_id BIGINT,
    repo_name TEXT NOT NULL,
    org_login TEXT,
    payload JSONB,
    created_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_events_snapshot_repo ON events_snapshot(repo_name);
CREATE INDEX IF NOT EXISTS idx_events_snapshot_type ON events_snapshot(event_type);
CREATE INDEX IF NOT EXISTS idx_events_snapshot_actor ON events_snapshot(actor_login);
CREATE INDEX IF NOT EXISTS idx_events_snapshot_created ON events_snapshot(created_at);

CREATE OR REPLACE VIEW v_events_all AS
SELECT id, event_type, actor_login, actor_id, repo_name, org_login, payload, created_at,
       'webhook_org'::text AS source
FROM events_webhook_org
UNION ALL
SELECT id, event_type, actor_login, actor_id, repo_name, org_login, payload, created_at,
       'webhook_repo'::text
FROM events_webhook_repo
UNION ALL
SELECT id, event_type, actor_login, actor_id, repo_name, org_login, payload, created_at,
       'events_api'::text
FROM events_api
UNION ALL
SELECT id, event_type, actor_login, actor_id, repo_name, org_login, payload, created_at,
       'snapshot'::text
FROM events_snapshot;

CREATE TABLE IF NOT EXISTS workflow_files (
    repo_name TEXT NOT NULL,
    ref TEXT NOT NULL,
    path TEXT NOT NULL,
    content TEXT,
    sha TEXT,
    fetched_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (repo_name, ref, path)
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'workflow_files' AND column_name = 'ref'
    ) THEN
        DELETE FROM workflow_files;
        ALTER TABLE workflow_files ADD COLUMN ref TEXT NOT NULL;
        ALTER TABLE workflow_files DROP CONSTRAINT workflow_files_pkey;
        ALTER TABLE workflow_files ADD PRIMARY KEY (repo_name, ref, path);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_workflow_files_repo ON workflow_files(repo_name);

CREATE TABLE IF NOT EXISTS repo_contributors (
    repo_name TEXT NOT NULL,
    actor_login TEXT NOT NULL,
    contributions INT DEFAULT 0,
    fetched_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (repo_name, actor_login)
);

CREATE INDEX IF NOT EXISTS idx_repo_contributors_login ON repo_contributors(actor_login);

CREATE TABLE IF NOT EXISTS workflow_runs (
    id TEXT PRIMARY KEY,
    repo_name TEXT NOT NULL,
    workflow_name TEXT,
    workflow_path TEXT,
    head_branch TEXT,
    head_sha TEXT,
    event TEXT,
    status TEXT,
    conclusion TEXT,
    actor_login TEXT,
    run_started_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    payload JSONB,
    source TEXT
);

CREATE INDEX IF NOT EXISTS idx_workflow_runs_repo ON workflow_runs(repo_name);
CREATE INDEX IF NOT EXISTS idx_workflow_runs_actor ON workflow_runs(actor_login);
CREATE INDEX IF NOT EXISTS idx_workflow_runs_event ON workflow_runs(event);
CREATE INDEX IF NOT EXISTS idx_workflow_runs_created ON workflow_runs(created_at);

CREATE TABLE IF NOT EXISTS findings (
    id SERIAL PRIMARY KEY,
    rule_id TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low')),
    repo_name TEXT NOT NULL,
    actor_login TEXT,
    event_id TEXT,
    description TEXT NOT NULL,
    evidence JSONB,
    is_candidate BOOLEAN NOT NULL DEFAULT false,
    status TEXT NOT NULL DEFAULT 'open'
        CHECK (status IN ('open', 'acknowledged', 'dismissed', 'escalated')),
    status_note TEXT,
    status_updated_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now()
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'findings' AND column_name = 'is_candidate'
    ) THEN
        ALTER TABLE findings ADD COLUMN is_candidate BOOLEAN NOT NULL DEFAULT false;
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'findings' AND column_name = 'status'
    ) THEN
        ALTER TABLE findings ADD COLUMN status TEXT NOT NULL DEFAULT 'open'
            CHECK (status IN ('open', 'acknowledged', 'dismissed', 'escalated'));
        ALTER TABLE findings ADD COLUMN status_note TEXT;
        ALTER TABLE findings ADD COLUMN status_updated_at TIMESTAMPTZ;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_findings_status ON findings(status);

CREATE INDEX IF NOT EXISTS idx_findings_rule ON findings(rule_id);
CREATE INDEX IF NOT EXISTS idx_findings_severity ON findings(severity);
CREATE INDEX IF NOT EXISTS idx_findings_repo ON findings(repo_name);
CREATE INDEX IF NOT EXISTS idx_findings_actor ON findings(actor_login);
CREATE INDEX IF NOT EXISTS idx_findings_created ON findings(created_at);
CREATE INDEX IF NOT EXISTS idx_findings_candidate ON findings(is_candidate);

CREATE UNIQUE INDEX IF NOT EXISTS idx_findings_dedup_event
    ON findings(rule_id, event_id)
    WHERE event_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_findings_dedup_no_event
    ON findings(rule_id, repo_name, COALESCE(actor_login, ''))
    WHERE event_id IS NULL;

CREATE TABLE IF NOT EXISTS push_commits (
    sha TEXT NOT NULL,
    repo_name TEXT NOT NULL,
    push_event_id TEXT,
    author_login TEXT,
    author_email TEXT,
    author_name TEXT,
    author_date TIMESTAMPTZ,
    committer_login TEXT,
    committer_email TEXT,
    committer_name TEXT,
    committer_date TIMESTAMPTZ,
    verified BOOLEAN,
    verification_reason TEXT,
    parents TEXT[],
    files_changed JSONB,
    message_headline TEXT,
    ref TEXT,
    before_sha TEXT,
    fetched_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (sha, repo_name)
);

CREATE INDEX IF NOT EXISTS idx_push_commits_repo ON push_commits(repo_name);
CREATE INDEX IF NOT EXISTS idx_push_commits_committer_date ON push_commits(committer_date);
CREATE INDEX IF NOT EXISTS idx_push_commits_author_date ON push_commits(author_date);

CREATE TABLE IF NOT EXISTS commit_author_search (
    author_email TEXT NOT NULL,
    repo_full_name TEXT NOT NULL,
    owner TEXT NOT NULL,
    sha TEXT NOT NULL,
    author_name TEXT,
    identity_kind TEXT,
    source_repo TEXT,
    found_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (author_email, repo_full_name, sha)
);

CREATE INDEX IF NOT EXISTS idx_commit_author_search_email ON commit_author_search(author_email);
CREATE INDEX IF NOT EXISTS idx_commit_author_search_owner ON commit_author_search(owner);
CREATE INDEX IF NOT EXISTS idx_commit_author_search_found ON commit_author_search(found_at);

CREATE TABLE IF NOT EXISTS git_repo_checks (
    id SERIAL PRIMARY KEY,
    repo_name TEXT NOT NULL,
    check_type TEXT NOT NULL,
    result JSONB NOT NULL,
    fetched_at TIMESTAMPTZ DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_git_repo_checks_dedup
    ON git_repo_checks(repo_name, check_type);
CREATE INDEX IF NOT EXISTS idx_git_repo_checks_repo
    ON git_repo_checks(repo_name);
CREATE INDEX IF NOT EXISTS idx_git_repo_checks_type
    ON git_repo_checks(check_type);

CREATE TABLE IF NOT EXISTS repo_tags (
    repo_name TEXT NOT NULL,
    tag_name TEXT NOT NULL,
    tag_sha TEXT NOT NULL,
    commit_sha TEXT,
    tag_type TEXT,
    fetched_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (repo_name, tag_name)
);

CREATE INDEX IF NOT EXISTS idx_repo_tags_repo ON repo_tags(repo_name);

CREATE TABLE IF NOT EXISTS repo_tags_history (
    id SERIAL PRIMARY KEY,
    repo_name TEXT NOT NULL,
    tag_name TEXT NOT NULL,
    old_sha TEXT NOT NULL,
    new_sha TEXT NOT NULL,
    detected_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_repo_tags_history_repo ON repo_tags_history(repo_name);
CREATE INDEX IF NOT EXISTS idx_repo_tags_history_detected ON repo_tags_history(detected_at);

CREATE TABLE IF NOT EXISTS repo_activities (
    id TEXT PRIMARY KEY,
    repo_name TEXT NOT NULL,
    activity_type TEXT NOT NULL,
    actor_login TEXT,
    actor_id BIGINT,
    ref TEXT,
    before_sha TEXT,
    after_sha TEXT,
    timestamp TIMESTAMPTZ,
    payload JSONB,
    source TEXT
);

CREATE INDEX IF NOT EXISTS idx_repo_activities_repo ON repo_activities(repo_name);
CREATE INDEX IF NOT EXISTS idx_repo_activities_type ON repo_activities(activity_type);
CREATE INDEX IF NOT EXISTS idx_repo_activities_actor ON repo_activities(actor_login);
CREATE INDEX IF NOT EXISTS idx_repo_activities_ref ON repo_activities(ref);
CREATE INDEX IF NOT EXISTS idx_repo_activities_timestamp ON repo_activities(timestamp);

CREATE TABLE IF NOT EXISTS webhook_deliveries (
    delivery_id TEXT NOT NULL,
    source TEXT NOT NULL,
    event_type TEXT NOT NULL,
    repo_name TEXT,
    received_at TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (delivery_id, source)
);

CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_received ON webhook_deliveries(received_at);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_source ON webhook_deliveries(source);
CREATE INDEX IF NOT EXISTS idx_webhook_deliveries_event_type ON webhook_deliveries(event_type);

CREATE OR REPLACE VIEW v_audit_events AS
SELECT
    source                                              AS source,
    repo_name                                           AS repo_name,
    COALESCE(created_at, now())                         AS ts,
    event_type                                          AS kind,
    payload->>'ref'                                     AS ref,
    COALESCE(payload->>'head', payload->>'after')       AS sha,
    actor_login                                         AS actor,
    payload                                             AS details
FROM v_events_all
UNION ALL
SELECT
    'activities_api'::text,
    repo_name,
    COALESCE(timestamp, now()),
    activity_type,
    ref,
    after_sha,
    actor_login,
    payload
FROM repo_activities
UNION ALL
SELECT
    'commits_api'::text,
    repo_name,
    COALESCE(author_date, committer_date, fetched_at),
    'Commit',
    ref,
    sha,
    COALESCE(author_login, author_email),
    jsonb_build_object(
        'author_date', author_date,
        'committer_date', committer_date,
        'author_email', author_email,
        'committer_email', committer_email,
        'verified', verified,
        'message_headline', message_headline,
        'before_sha', before_sha,
        'parents', parents
    )
FROM push_commits
UNION ALL
SELECT
    'tags_api'::text,
    repo_name,
    detected_at,
    'Tag.Drifted',
    'refs/tags/' || tag_name,
    new_sha,
    NULL,
    jsonb_build_object('tag_name', tag_name, 'old_sha', old_sha, 'new_sha', new_sha)
FROM repo_tags_history
UNION ALL
SELECT
    'git_forensics'::text,
    repo_name,
    fetched_at,
    check_type,
    NULL,
    NULL,
    NULL,
    result
FROM git_repo_checks
WHERE check_type IN ('replace_refs', 'gitattributes',
                     'symlinks', 'unicode_artifacts', 'tag_provenance')
UNION ALL
SELECT
    source,
    repo_name,
    received_at,
    event_type,
    NULL,
    NULL,
    NULL,
    NULL
FROM webhook_deliveries;
