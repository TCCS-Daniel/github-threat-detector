import type { Finding, RelatedResponse, Severity, TimelineResponse } from './types'

async function getJson<T>(url: string): Promise<T> {
  const res = await fetch(url)
  const body = await res.text()
  if (!res.ok) {
    throw new Error(`${res.status} ${res.statusText}: ${body.slice(0, 200)}`)
  }
  const type = res.headers.get('content-type') || ''
  if (!type.includes('application/json')) {
    throw new Error(
      `Expected JSON from ${url}, got ${type || 'unknown'} — is the API running on :8000?`,
    )
  }
  return JSON.parse(body) as T
}

export function fetchOrgs() {
  return getJson<{ orgs: string[] }>('/api/orgs')
}

export function fetchRepos(org?: string) {
  const q = org ? `?org=${encodeURIComponent(org)}` : ''
  return getJson<{ repos: string[] }>(`/api/repos${q}`)
}

export function fetchFindings(params: {
  org?: string
  repo?: string
  severity?: Severity[]
  since?: string
}) {
  const sp = new URLSearchParams()
  if (params.org) sp.set('org', params.org)
  if (params.repo) sp.set('repo', params.repo)
  if (params.since) sp.set('since', params.since)
  for (const s of params.severity || []) sp.append('severity', s)
  const q = sp.toString()
  return getJson<{ findings: Finding[] }>(`/api/findings${q ? `?${q}` : ''}`)
}

export function fetchFinding(id: number) {
  return getJson<Finding>(`/api/findings/${id}`)
}

export function fetchRelated(id: number, since?: string, repo?: string) {
  const sp = new URLSearchParams()
  if (since) sp.set('since', since)
  if (repo) sp.set('repo', repo)
  const q = sp.toString()
  return getJson<RelatedResponse>(`/api/findings/${id}/related${q ? `?${q}` : ''}`)
}

export function fetchRepoTimeline(params: {
  repo: string
  center?: string
  window_days: number
}) {
  const sp = new URLSearchParams({
    repo: params.repo,
    window_days: String(params.window_days),
  })
  if (params.center) sp.set('center', params.center)
  return getJson<TimelineResponse>(`/api/timeline/repo?${sp}`)
}

export function fetchCompoundTimeline(params: {
  f1: number
  f2: number
  window_days: number
}) {
  const sp = new URLSearchParams({
    f1: String(params.f1),
    f2: String(params.f2),
    window_days: String(params.window_days),
  })
  return getJson<TimelineResponse>(`/api/timeline/compound?${sp}`)
}
