import { useCallback, useEffect, useMemo, useRef, useState, type MouseEvent as ReactMouseEvent } from 'react'
import { createPortal } from 'react-dom'
import {
  fetchCompoundTimeline,
  fetchFinding,
  fetchFindings,
  fetchOrgs,
  fetchRelated,
  fetchRepoTimeline,
  fetchRepos,
  fetchRunStatus,
  startRun,
  type RunStatus,
} from './api'
import { CorrelationGraph } from './CorrelationGraph'
import type { EntityKey, Facet, Finding, RelatedResponse, Severity, TimelineResponse } from './types'

const LIST_FACETS: EntityKey[] = ['commit', 'release', 'tag', 'user', 'workflow', 'repo']
const DEFAULT_LIST_W = 300
const DEFAULT_RELATED_W = 340
const MIN_LIST_W = 220
const MIN_DETAIL_W = 240
const MIN_RELATED_W = 260

const SEVERITIES: Severity[] = ['critical', 'high', 'medium', 'low']
const WINDOW_OPTIONS = [1, 7, 14, 30]
const SINCE_OPTIONS = ['15m', '1h', '4h', '1d', '7d'] as const
type SinceOption = (typeof SINCE_OPTIONS)[number] | ''

function readParams() {
  const sp = new URLSearchParams(window.location.search)
  const severity = sp.getAll('severity').filter((s): s is Severity =>
    SEVERITIES.includes(s as Severity),
  )
  const sinceRaw = sp.get('since') || ''
  const since = (SINCE_OPTIONS as readonly string[]).includes(sinceRaw)
    ? (sinceRaw as SinceOption)
    : ''
  return {
    org: sp.get('org') || '',
    repo: sp.get('repo') || '',
    f1: sp.get('f1') ? Number(sp.get('f1')) : null,
    f2: sp.get('f2') ? Number(sp.get('f2')) : null,
    window_days: Number(sp.get('window_days') || 7) || 7,
    severity,
    since,
  }
}

function writeParams(state: {
  org: string
  repo: string
  f1: number | null
  f2: number | null
  window_days: number
  severity: Severity[]
  since: SinceOption
}) {
  const sp = new URLSearchParams()
  if (state.org) sp.set('org', state.org)
  if (state.repo) sp.set('repo', state.repo)
  if (state.since) sp.set('since', state.since)
  if (state.f1 != null) sp.set('f1', String(state.f1))
  if (state.f2 != null) sp.set('f2', String(state.f2))
  if (state.window_days !== 7) sp.set('window_days', String(state.window_days))
  for (const s of state.severity) sp.append('severity', s)
  const q = sp.toString()
  const next = q ? `?${q}` : window.location.pathname
  window.history.replaceState(null, '', next)
}

function formatEvidence(value: unknown): string {
  if (value == null) return '—'
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value)
  } catch {
    return String(value)
  }
}

function FindingMeta({ f }: { f: Finding }) {
  return (
    <div className="meta">
      <span className={`badge sev-${f.severity}`}>{f.severity}</span>
      <span>{f.rule_id}</span>
      {f.is_candidate ? <span className="badge candidate">candidate</span> : null}
    </div>
  )
}

function withoutCandidates(related: RelatedResponse): RelatedResponse {
  const facets = { ...related.facets }
  for (const key of Object.keys(facets) as EntityKey[]) {
    const facet = facets[key]
    if (facet.status !== 'ok') continue
    const findings = facet.findings.filter((f) => !f.is_candidate)
    const removed = facet.findings.length - findings.length
    if (findings.length === 0) {
      facets[key] = { ...facet, findings, total: 0, status: 'empty' }
    } else if (removed > 0) {
      facets[key] = {
        ...facet,
        findings,
        total: Math.max(findings.length, facet.total - removed),
      }
    }
  }
  return { ...related, facets }
}

function FacetBlock({
  name,
  facet,
  onSelect,
  onPin,
  highlight,
}: {
  name: string
  facet: Facet
  onSelect: (id: number) => void
  onPin: (id: number) => void
  highlight: boolean
}) {
  return (
    <section className="facet" id={`facet-${name}`} data-highlight={highlight || undefined}>
      <div className="facet-head">
        <strong>{name}</strong>
        <span>{facet.value || '—'}</span>
      </div>
      {facet.status === 'absent' ? (
        <p className="facet-empty">not in this finding</p>
      ) : null}
      {facet.status === 'empty' ? (
        <p className="facet-empty">No other findings share this {name}.</p>
      ) : null}
      {facet.status === 'ok'
        ? facet.findings.map((peer) => (
            <div key={peer.id} className="peer">
              <div className="peer-top">
                <span className={`badge sev-${peer.severity}`}>{peer.severity}</span>
                <span>{peer.rule_id}</span>
                {peer.is_candidate ? <span className="badge candidate">candidate</span> : null}
              </div>
              <div>{peer.description}</div>
              <div className="peer-actions">
                <button type="button" onClick={() => onSelect(peer.id)}>
                  Open
                </button>
                <button type="button" onClick={() => onPin(peer.id)}>
                  Pin as B
                </button>
              </div>
            </div>
          ))
        : null}
      {facet.status === 'ok' && facet.total > facet.findings.length ? (
        <p className="facet-empty">…and {facet.total - facet.findings.length} more</p>
      ) : null}
    </section>
  )
}

export default function App() {
  const initial = useMemo(() => readParams(), [])
  const [orgs, setOrgs] = useState<string[]>([])
  const [repos, setRepos] = useState<string[]>([])
  const [org, setOrg] = useState(initial.org)
  const [repo, setRepo] = useState(initial.repo)
  const [severity, setSeverity] = useState<Severity[]>(initial.severity)
  const [since, setSince] = useState<SinceOption>(initial.since)
  const [findings, setFindings] = useState<Finding[]>([])
  const [selectedId, setSelectedId] = useState<number | null>(initial.f1)
  const [selected, setSelected] = useState<Finding | null>(null)
  const [related, setRelated] = useState<RelatedResponse | null>(null)
  const [pinB, setPinB] = useState<number | null>(initial.f2)
  const [windowDays, setWindowDays] = useState(initial.window_days)
  const [timelineMode, setTimelineMode] = useState<'repo' | 'compound'>(
    initial.f2 ? 'compound' : 'repo',
  )
  const [timeline, setTimeline] = useState<TimelineResponse | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [focusFacet, setFocusFacet] = useState<string | null>(null)
  const [relatedView, setRelatedView] = useState<'list' | 'graph'>('list')
  const [hideCandidates, setHideCandidates] = useState(false)
  const [graphFullscreen, setGraphFullscreen] = useState(false)
  const [listW, setListW] = useState(DEFAULT_LIST_W)
  const [relatedW, setRelatedW] = useState(DEFAULT_RELATED_W)
  const [run, setRun] = useState<RunStatus | null>(null)
  const [refresh, setRefresh] = useState(0)
  const mainRef = useRef<HTMLDivElement>(null)

  const running = run?.status === 'running'

  async function triggerRun() {
    try {
      setError(null)
      const status = await startRun()
      setRun(status)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  // Pick up a job already in flight (e.g. after a page reload).
  useEffect(() => {
    fetchRunStatus()
      .then((s) => {
        if (s.status === 'running') setRun(s)
      })
      .catch(() => {})
  }, [])

  useEffect(() => {
    if (!running) return
    const t = window.setInterval(() => {
      fetchRunStatus()
        .then((s) => {
          setRun(s)
          if (s.status === 'done') setRefresh((n) => n + 1)
          if (s.status === 'error') setError(`Collect + analyze failed: ${s.error}`)
        })
        .catch((e: Error) => setError(e.message))
    }, 2000)
    return () => window.clearInterval(t)
  }, [running])

  useEffect(() => {
    if (!graphFullscreen) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setGraphFullscreen(false)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [graphFullscreen])

  useEffect(() => {
    if (!selected || !related) setGraphFullscreen(false)
  }, [selected, related])

  const startResize = useCallback(
    (which: 'list' | 'related', ev: ReactMouseEvent) => {
      ev.preventDefault()
      const startX = ev.clientX
      const startList = listW
      const startRelated = relatedW
      const main = mainRef.current
      const mainWidth = main?.clientWidth ?? 1200

      const onMove = (e: MouseEvent) => {
        const dx = e.clientX - startX
        if (which === 'list') {
          const maxList = mainWidth - MIN_DETAIL_W - relatedW - 16
          setListW(Math.min(maxList, Math.max(MIN_LIST_W, startList + dx)))
        } else {
          const maxRelated = mainWidth - MIN_DETAIL_W - listW - 16
          setRelatedW(Math.min(maxRelated, Math.max(MIN_RELATED_W, startRelated - dx)))
        }
      }
      const onUp = () => {
        window.removeEventListener('mousemove', onMove)
        window.removeEventListener('mouseup', onUp)
        document.body.classList.remove('resizing-cols')
      }
      document.body.classList.add('resizing-cols')
      window.addEventListener('mousemove', onMove)
      window.addEventListener('mouseup', onUp)
    },
    [listW, relatedW],
  )

  function widenRelatedForNarration() {
    const mainWidth = mainRef.current?.clientWidth ?? 1200
    const target = Math.floor(mainWidth * 0.52)
    const maxRelated = mainWidth - MIN_DETAIL_W - MIN_LIST_W - 16
    setRelatedW(Math.min(maxRelated, Math.max(MIN_RELATED_W, target)))
    setListW(MIN_LIST_W)
    setRelatedView('graph')
  }

  function resetLayout() {
    setListW(DEFAULT_LIST_W)
    setRelatedW(DEFAULT_RELATED_W)
  }

  useEffect(() => {
    fetchOrgs()
      .then((r) => setOrgs(r.orgs))
      .catch((e: Error) => setError(e.message))
  }, [refresh])

  useEffect(() => {
    fetchRepos(org || undefined)
      .then((r) => setRepos(r.repos))
      .catch((e: Error) => setError(e.message))
  }, [org, refresh])

  useEffect(() => {
    writeParams({
      org,
      repo,
      f1: selectedId,
      f2: pinB,
      window_days: windowDays,
      severity,
      since,
    })
  }, [org, repo, selectedId, pinB, windowDays, severity, since])

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setError(null)
    fetchFindings({
      org: org || undefined,
      repo: repo || undefined,
      severity: severity.length ? severity : undefined,
      since: since || undefined,
    })
      .then((r) => {
        if (cancelled) return
        setFindings(r.findings)
        setSelectedId((prev) => {
          if (prev != null && r.findings.some((f) => f.id === prev)) return prev
          return r.findings[0]?.id ?? null
        })
      })
      .catch((e: Error) => {
        if (!cancelled) setError(e.message)
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [org, repo, severity, since, refresh])

  useEffect(() => {
    if (selectedId == null) {
      setSelected(null)
      setRelated(null)
      return
    }
    setSelected(null)
    setRelated(null)
    setFocusFacet(null)
    setError(null)
    let cancelled = false
    Promise.all([
      fetchFinding(selectedId),
      fetchRelated(selectedId, since || undefined, repo || undefined),
    ])
      .then(([f, rel]) => {
        if (!cancelled) {
          setSelected(f)
          setRelated(rel)
        }
      })
      .catch((e: Error) => {
        if (!cancelled) setError(e.message)
      })
    return () => {
      cancelled = true
    }
  }, [selectedId, since, repo])

  useEffect(() => {
    if (!selected) {
      setTimeline(null)
      return
    }
    setTimeline(null)
    setError(null)
    let cancelled = false
    const run = async () => {
      try {
        if (timelineMode === 'compound' && pinB != null) {
          const tl = await fetchCompoundTimeline({
            f1: selected.id,
            f2: pinB,
            window_days: windowDays,
          })
          if (!cancelled) setTimeline(tl)
        } else {
          const tl = await fetchRepoTimeline({
            repo: selected.repo_name,
            center: selected.created_at,
            window_days: windowDays,
          })
          if (!cancelled) setTimeline(tl)
        }
      } catch (e) {
        if (!cancelled) setError((e as Error).message)
      }
    }
    void run()
    return () => {
      cancelled = true
    }
  }, [selected, pinB, timelineMode, windowDays])

  useEffect(() => {
    if (!focusFacet || relatedView !== 'list') return
    const el = document.getElementById(`facet-${focusFacet}`)
    el?.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
    const t = window.setTimeout(() => setFocusFacet(null), 1600)
    return () => window.clearTimeout(t)
  }, [focusFacet, related, relatedView])

  const grouped = useMemo(() => {
    const map = new Map<Severity, Finding[]>()
    for (const s of SEVERITIES) map.set(s, [])
    for (const f of findings) map.get(f.severity)?.push(f)
    return map
  }, [findings])

  const relatedForView = useMemo(() => {
    if (!related) return null
    return hideCandidates ? withoutCandidates(related) : related
  }, [related, hideCandidates])

  const filtersActive = Boolean(org || repo || severity.length || since)

  function toggleSeverity(s: Severity) {
    setSeverity((prev) => (prev.includes(s) ? prev.filter((x) => x !== s) : [...prev, s]))
  }

  function clearFilters() {
    setOrg('')
    setRepo('')
    setSeverity([])
    setSince('')
  }

  function selectFinding(id: number) {
    setSelectedId(id)
  }

  function pinFinding(id: number) {
    if (id === selectedId) return
    setPinB(id)
    setTimelineMode('compound')
  }

  function clearPin() {
    setPinB(null)
    setTimelineMode('repo')
  }

  const graphOverlay =
    graphFullscreen && selected && relatedForView
      ? createPortal(
          <div className="graph-overlay" role="dialog" aria-label="Correlation graph full page">
            <div className="graph-overlay-bar">
              <div>
                <strong>Correlation graph</strong>
                <span className="graph-overlay-meta">
                  {selected.rule_id}
                  {pinB != null ? ` · pinned B #${pinB}` : ''}
                  {hideCandidates ? ' · candidates hidden' : ''}
                </span>
              </div>
              <button type="button" className="graph-overlay-close" onClick={() => setGraphFullscreen(false)}>
                Close (Esc)
              </button>
            </div>
            <div className="graph-overlay-body">
              <CorrelationGraph
                key={`fs-${selected.id}-${hideCandidates ? 'nc' : 'all'}`}
                focus={selected}
                related={relatedForView}
                pinB={pinB}
                onSelect={selectFinding}
                onPin={pinFinding}
              />
            </div>
          </div>,
          document.body,
        )
      : null

  return (
    <>
    <div className="app">
      <header className="topbar">
        <h1 className="brand">GitHub Threat Detector</h1>
        <div className="field">
          <label htmlFor="org">Org</label>
          <select
            id="org"
            value={org}
            onChange={(e) => {
              setOrg(e.target.value)
              setRepo('')
            }}
          >
            <option value="">All orgs</option>
            {orgs.map((o) => (
              <option key={o} value={o}>
                {o}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label htmlFor="repo">Repo</label>
          <select id="repo" value={repo} onChange={(e) => setRepo(e.target.value)}>
            <option value="">All repos</option>
            {repos.map((r) => (
              <option key={r} value={r}>
                {r}
              </option>
            ))}
          </select>
        </div>
        <div className="field">
          <label>Severity</label>
          <div className="sev-filters">
            {SEVERITIES.map((s) => (
              <button
                key={s}
                type="button"
                className={severity.includes(s) ? 'on' : ''}
                onClick={() => toggleSeverity(s)}
              >
                {s}
              </button>
            ))}
          </div>
        </div>
        <div className="field">
          <label>Time</label>
          <div className="sev-filters">
            <button
              type="button"
              className={since === '' ? 'on' : ''}
              onClick={() => setSince('')}
            >
              all
            </button>
            {SINCE_OPTIONS.map((s) => (
              <button
                key={s}
                type="button"
                className={since === s ? 'on' : ''}
                onClick={() => setSince(s)}
              >
                {s}
              </button>
            ))}
          </div>
        </div>
        <div className="field run-field">
          <label>Pipeline</label>
          <div className="run-controls">
            <button
              type="button"
              className={`run-btn${running ? ' running' : ''}`}
              disabled={running}
              onClick={triggerRun}
              title="Collect events for the configured repos/orgs, then run all analyzers"
            >
              {running
                ? run?.step === 'analyze'
                  ? 'Analyzing…'
                  : 'Collecting…'
                : 'Collect + Analyze'}
            </button>
            {running && run?.detail ? (
              <span className="run-note">{run.detail}</span>
            ) : null}
            {!running && run?.status === 'done' && run.result ? (
              <span className="run-note ok">
                ✓ {run.result.new_events ?? 0} events · {run.result.findings ?? 0} findings
                {run.result.collect_errors
                  ? ` · ${run.result.collect_errors} steps skipped`
                  : ''}
              </span>
            ) : null}
          </div>
        </div>
        {error ? (
          <div className="banner-error" role="alert">
            Error: {error}
          </div>
        ) : null}
      </header>

      <div className="main" ref={mainRef}>
        <section className="panel list-panel" style={{ width: listW, flex: '0 0 auto' }}>
          <h2>Findings {loading ? '…' : `(${findings.length})`}</h2>
          {!loading && findings.length === 0 ? (
            <div className="empty">
              {filtersActive ? (
                <>
                  No findings match this filter.
                  <br />
                  <button type="button" className="linkish" onClick={clearFilters}>
                    Clear filters
                  </button>
                </>
              ) : (
                <>No findings yet. Run analyzers to populate.</>
              )}
            </div>
          ) : null}
          {SEVERITIES.map((s) => {
            const rows = grouped.get(s) || []
            if (!rows.length) return null
            return (
              <div key={s}>
                <div className="band">
                  {s} ({rows.length})
                </div>
                {rows.map((f) => (
                  <button
                    key={f.id}
                    type="button"
                    className={`finding-row${selectedId === f.id ? ' active' : ''}`}
                    onClick={() => selectFinding(f.id)}
                  >
                    <FindingMeta f={f} />
                    <div className="desc">{f.description}</div>
                    <div className="meta">
                      <span>{f.repo_name}</span>
                      {f.actor_login ? <span>{f.actor_login}</span> : null}
                    </div>
                  </button>
                ))}
              </div>
            )
          })}
        </section>

        <div
          className="col-splitter"
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize findings column"
          onMouseDown={(e) => startResize('list', e)}
        />

        <section className="panel detail-panel">
          <h2>Detail</h2>
          {!selected ? (
            <div className="empty">Select a finding from the list to inspect evidence and correlated resources.</div>
          ) : (
            <>
              <div className="detail-title">
                <h3>{selected.rule_id}</h3>
                <span className={`badge sev-${selected.severity}`}>{selected.severity}</span>
                {selected.is_candidate ? <span className="badge candidate">candidate</span> : null}
              </div>
              <p className="detail-desc">{selected.description}</p>
              <div className="chips">
                {LIST_FACETS.map((key) => {
                  const value = selected.entities[key]
                  if (!value) return null
                  const shown =
                    key === 'commit' ? value.slice(0, 12) : value
                  return (
                    <button
                      key={key}
                      type="button"
                      className="chip"
                      onClick={() => {
                        setRelatedView('list')
                        setFocusFacet(key)
                      }}
                    >
                      {key}: {shown}
                    </button>
                  )
                })}
              </div>
              <dl className="evidence">
                {Object.entries(selected.evidence || {}).map(([k, v]) => (
                  <div className="evidence-row" key={k}>
                    <dt>{k}</dt>
                    <dd>{formatEvidence(v)}</dd>
                  </div>
                ))}
              </dl>
            </>
          )}
        </section>

        <div
          className="col-splitter"
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize related column"
          onMouseDown={(e) => startResize('related', e)}
        />

        <section
          className={`panel related-panel${relatedView === 'graph' ? ' graph-mode' : ''}`}
          style={{ width: relatedW, flex: '0 0 auto' }}
        >
          <div className="panel-head">
            <h2>Related</h2>
            <div className="related-controls">
              {selected && relatedForView ? (
                <div className="mode-toggle">
                  <button
                    type="button"
                    className={relatedView === 'list' ? 'on' : ''}
                    onClick={() => setRelatedView('list')}
                  >
                    List
                  </button>
                  <button
                    type="button"
                    className={relatedView === 'graph' ? 'on' : ''}
                    onClick={() => setRelatedView('graph')}
                  >
                    Graph
                  </button>
                </div>
              ) : null}
              {selected && related ? (
                <div className="mode-toggle">
                  <button
                    type="button"
                    className={hideCandidates ? 'on' : ''}
                    title="Hide candidate findings from related list and graph"
                    onClick={() => setHideCandidates((v) => !v)}
                  >
                    Hide candidates
                  </button>
                </div>
              ) : null}
              <div className="mode-toggle">
                <button
                  type="button"
                  title="Widen related for narration"
                  disabled={!selected || !related}
                  onClick={widenRelatedForNarration}
                >
                  Widen
                </button>
                <button
                  type="button"
                  title="Show graph over the full page"
                  disabled={!selected || !related}
                  onClick={() => {
                    setRelatedView('graph')
                    setGraphFullscreen(true)
                  }}
                >
                  Full page
                </button>
                <button type="button" title="Reset column widths" onClick={resetLayout}>
                  Reset
                </button>
              </div>
            </div>
          </div>
          {!selected || !relatedForView ? (
            <div className="empty">Appears when a finding is selected.</div>
          ) : relatedView === 'graph' ? (
            graphFullscreen ? (
              <div className="empty">Graph is open full page · Esc to close</div>
            ) : (
              <CorrelationGraph
                key={`${selected.id}-${hideCandidates ? 'nc' : 'all'}`}
                focus={selected}
                related={relatedForView}
                pinB={pinB}
                onSelect={selectFinding}
                onPin={pinFinding}
              />
            )
          ) : (
            <>
              {LIST_FACETS.map((name) => (
                <FacetBlock
                  key={name}
                  name={name}
                  facet={relatedForView.facets[name]}
                  onSelect={selectFinding}
                  onPin={pinFinding}
                  highlight={focusFacet === name}
                />
              ))}
            </>
          )}
        </section>
      </div>

      <section className="timeline">
        <div className="timeline-bar">
          <h2>Timeline</h2>
          <div className="mode-toggle">
            <button
              type="button"
              className={timelineMode === 'repo' ? 'on' : ''}
              onClick={() => setTimelineMode('repo')}
            >
              Repo
            </button>
            <button
              type="button"
              className={timelineMode === 'compound' ? 'on' : ''}
              disabled={pinB == null}
              onClick={() => pinB != null && setTimelineMode('compound')}
            >
              Pinned
            </button>
          </div>
          <div className="window-toggle">
            {WINDOW_OPTIONS.map((d) => (
              <button
                key={d}
                type="button"
                className={windowDays === d ? 'on' : ''}
                onClick={() => setWindowDays(d)}
              >
                ±{d}d
              </button>
            ))}
          </div>
          {pinB != null ? (
            <div className="pinned-note">
              Pin B: #{pinB}
              <button type="button" onClick={clearPin}>
                clear
              </button>
            </div>
          ) : null}
        </div>
        {!selected ? (
          <div className="empty">Select a finding to load its repo timeline.</div>
        ) : !timeline || timeline.events.length === 0 ? (
          <div className="empty">No events in this window for {timeline?.repos?.join(', ') || selected.repo_name}.</div>
        ) : (
          <div className="timeline-track">
            {timeline.events.map((ev, idx) => (
              <div
                key={`${ev.ts}-${ev.kind}-${idx}`}
                className={`tl-item${ev.pin ? ' pin-row' : ''}`}
                title={ev.summary}
              >
                <div className="tl-time">{ev.ts?.replace('T', ' ').replace(/\+.*/, 'Z')}</div>
                <div className="tl-dot" />
                <div className="tl-body">
                  <div className="kind">
                    {ev.pin ? `◆ ${ev.pin.severity} ${ev.pin.rule_id}` : ev.kind}
                  </div>
                  <div className="sub">
                    {[ev.repo_name, ev.actor, ev.ref, ev.sha ? String(ev.sha).slice(0, 12) : null]
                      .filter(Boolean)
                      .join(' · ')}
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
    {graphOverlay}
    </>
  )
}
