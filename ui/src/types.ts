export type Severity = 'critical' | 'high' | 'medium' | 'low'

export type FindingStatus = 'open' | 'acknowledged' | 'dismissed' | 'escalated'

export type EntityKey = 'repo' | 'user' | 'tag' | 'workflow' | 'commit' | 'release'

export type Entities = {
  org: string | null
  repo: string | null
  user: string | null
  tag: string | null
  workflow: string | null
  commit: string | null
  release: string | null
}

export type Finding = {
  id: number
  rule_id: string
  severity: Severity
  repo_name: string
  actor_login: string | null
  event_id: string | null
  description: string
  evidence: Record<string, unknown>
  is_candidate: boolean
  status: FindingStatus
  status_note: string | null
  status_updated_at: string | null
  created_at: string
  entities: Entities
}

export type FacetStatus = 'ok' | 'empty' | 'absent'

export type Facet = {
  value: string | null
  status: FacetStatus
  total: number
  findings: Finding[]
}

export type RelatedResponse = {
  finding_id: number
  entities: Entities
  facets: Record<EntityKey, Facet>
}

export type TimelinePin = {
  finding_id: number
  rule_id: string
  severity: Severity
  repo_name?: string
  ts?: string
}

export type TimelineEvent = {
  ts: string
  source: string | null
  kind: string | null
  repo_name: string | null
  actor: string | null
  ref: string | null
  sha: string | null
  summary: string
  pin: TimelinePin | null
}

export type TimelineResponse = {
  mode: 'repo' | 'compound'
  repos: string[]
  center: string
  window_days: number
  start: string
  end: string
  events: TimelineEvent[]
  pins: TimelinePin[]
  f1?: number
  f2?: number
}
