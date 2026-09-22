import { useEffect, useMemo, useRef, useState } from 'react'
import ForceGraph2D from 'react-force-graph-2d'
import type { EntityKey, Finding, RelatedResponse, Severity } from './types'

type GraphEntity = Exclude<EntityKey, 'repo'>

type GraphNode = {
  id: string
  kind: 'finding' | 'group' | GraphEntity
  label: string
  severity?: Severity
  findingId?: number
  ruleId?: string
  count?: number
  memberIds?: number[]
  isFocus?: boolean
  isPinned?: boolean
  ts?: number
  fx?: number
  fy?: number
  x?: number
  y?: number
}

type GraphLink = {
  source: string
  target: string
  facet: string
}

const SEV_RANK: Record<Severity, number> = {
  low: 0,
  medium: 1,
  high: 2,
  critical: 3,
}

function worseSeverity(a: Severity, b: Severity): Severity {
  return SEV_RANK[a] >= SEV_RANK[b] ? a : b
}

/** Keep in sync with --critical/--high/--medium/--low in index.css */
const SEV_COLOR: Record<Severity, string> = {
  critical: '#f85149',
  high: '#f0883e',
  medium: '#d29922',
  low: '#58a6ff',
}

/** Canvas colors; keep in sync with --bg/--inset in index.css. */
const CANVAS_BG = '#10151c'
const CANVAS_INK = '#c9d1d9'
const ICON_DETAIL = '#0d1117'

/** Graph hubs only — repo is list-only (too broad / star topology). */
const ENTITY_COLOR: Record<GraphEntity, string> = {
  commit: '#9198a1',
  release: '#a371f7',
  tag: '#d29922',
  user: '#539bf5',
  workflow: '#3fb950',
}

const FACET_LINK: Record<string, string> = {
  commit: '#545d68',
  release: '#8250df',
  tag: '#9e6a03',
  user: '#316dca',
  workflow: '#347d39',
}

/** Stronger IR pivots first; user is broad and creates star graphs. */
const GRAPH_FACETS: GraphEntity[] = ['commit', 'tag', 'release', 'workflow', 'user']
const BROAD_FACETS: GraphEntity[] = ['user']
const PEERS_PER_FACET = 24

function shortLabel(text: string, max = 22): string {
  if (text.length <= max) return text
  return `${text.slice(0, max - 1)}…`
}

function entityLabel(kind: GraphEntity, value: string): string {
  if (kind === 'commit') return value.slice(0, 7)
  if (kind === 'release') return shortLabel(value, 16)
  if (kind === 'tag') return shortLabel(value, 18)
  if (kind === 'user') return shortLabel(value, 16)
  return shortLabel(value.split('/').pop() || value, 16)
}

function availableFacets(related: RelatedResponse): GraphEntity[] {
  return GRAPH_FACETS.filter((facet) => {
    const block = related.facets[facet]
    return Boolean(block && block.status === 'ok' && block.value && block.findings.length)
  })
}

function defaultEnabled(facets: GraphEntity[]): Set<GraphEntity> {
  const strong = facets.filter((f) => !BROAD_FACETS.includes(f))
  if (strong.length >= 1 && facets.includes('user')) {
    return new Set(strong)
  }
  return new Set(facets)
}

function buildGraph(
  focus: Finding,
  related: RelatedResponse,
  pinB: number | null,
  enabled: Set<GraphEntity>,
  expandedRules: Set<string>,
): { nodes: GraphNode[]; links: GraphLink[] } {
  const nodes = new Map<string, GraphNode>()
  const links: GraphLink[] = []
  const linkKeys = new Set<string>()

  const addLink = (source: string, target: string, facet: string) => {
    const key = `${source}|${target}|${facet}`
    if (linkKeys.has(key)) return
    linkKeys.add(key)
    links.push({ source, target, facet })
  }

  const focusId = `f:${focus.id}`
  nodes.set(focusId, {
    id: focusId,
    kind: 'finding',
    label: focus.rule_id,
    severity: focus.severity,
    findingId: focus.id,
    isFocus: true,
    isPinned: pinB === focus.id,
  })

  type PeerEdge = { finding: Finding; entityId: string; facet: GraphEntity }
  const peerEdges: PeerEdge[] = []
  const peerById = new Map<number, Finding>()

  for (const facet of GRAPH_FACETS) {
    if (!enabled.has(facet)) continue
    const block = related.facets[facet]
    if (!block || block.status !== 'ok' || !block.value) continue

    const usePeers = block.findings
      .filter((p) => p.id !== focus.id)
      .slice(0, PEERS_PER_FACET)
    if (!usePeers.length) continue

    const entityId = `e:${facet}:${block.value}`
    if (!nodes.has(entityId)) {
      nodes.set(entityId, {
        id: entityId,
        kind: facet,
        label: entityLabel(facet, block.value),
      })
    }
    addLink(focusId, entityId, facet)

    for (const peer of usePeers) {
      peerById.set(peer.id, peer)
      peerEdges.push({ finding: peer, entityId, facet })
    }
  }

  type PeerRef = Pick<Finding, 'id' | 'rule_id' | 'severity' | 'created_at'>

  const toTs = (raw: string | undefined) => {
    if (!raw) return Date.parse(focus.created_at) || 0
    const n = Date.parse(raw)
    return Number.isFinite(n) ? n : Date.parse(focus.created_at) || 0
  }

  const byRule = new Map<string, PeerRef[]>()
  for (const peer of peerById.values()) {
    const list = byRule.get(peer.rule_id) || []
    if (list.some((p) => p.id === peer.id)) continue
    list.push(peer)
    byRule.set(peer.rule_id, list)
  }

  const ensureFinding = (peer: PeerRef) => {
    const peerId = `f:${peer.id}`
    if (!nodes.has(peerId)) {
      nodes.set(peerId, {
        id: peerId,
        kind: 'finding',
        label: peer.rule_id,
        severity: peer.severity,
        findingId: peer.id,
        isPinned: pinB === peer.id,
        ts: toTs(peer.created_at),
      })
    }
    return peerId
  }

  nodes.get(focusId)!.ts = toTs(focus.created_at)

  const shouldExpand = (ruleId: string, members: PeerRef[]) =>
    expandedRules.has(ruleId) ||
    members.length < 2 ||
    members.some((m) => m.id === pinB)

  const peerTarget = (peer: PeerRef) => {
    const members = byRule.get(peer.rule_id) || []
    if (shouldExpand(peer.rule_id, members)) return ensureFinding(peer)
    return `g:${peer.rule_id}`
  }

  for (const [ruleId, members] of byRule) {
    if (shouldExpand(ruleId, members)) {
      for (const peer of members) ensureFinding(peer)
      continue
    }

    const groupId = `g:${ruleId}`
    const severity = members.reduce(
      (acc, m) => worseSeverity(acc, m.severity),
      members[0].severity,
    )
    nodes.set(groupId, {
      id: groupId,
      kind: 'group',
      label: `${shortLabel(ruleId, 18)} ×${members.length}`,
      severity,
      ruleId,
      count: members.length,
      memberIds: members.map((m) => m.id),
      ts: Math.min(...members.map((m) => toTs(m.created_at))),
    })
  }

  for (const edge of peerEdges) {
    addLink(peerTarget(edge.finding), edge.entityId, edge.facet)
  }

  return { nodes: [...nodes.values()], links }
}

/** Pin X by finding time (earlier → left); coords centered at 0 for the camera. */
function applyTimelineLayout(
  graph: { nodes: GraphNode[]; links: GraphLink[] },
  width: number,
  height: number,
): { nodes: GraphNode[]; links: GraphLink[] } {
  const { nodes, links } = graph
  if (!nodes.length) return graph

  const tsMap = new Map<string, number>()
  for (const n of nodes) {
    if (n.ts != null && Number.isFinite(n.ts)) tsMap.set(n.id, n.ts)
  }

  for (let pass = 0; pass < 3; pass++) {
    for (const n of nodes) {
      if (n.kind === 'finding' || n.kind === 'group') continue
      const neigh: number[] = []
      for (const l of links) {
        const [s, t] = linkEnds(l)
        if (s === n.id && tsMap.has(t)) neigh.push(tsMap.get(t)!)
        if (t === n.id && tsMap.has(s)) neigh.push(tsMap.get(s)!)
      }
      if (neigh.length) {
        tsMap.set(n.id, neigh.reduce((a, b) => a + b, 0) / neigh.length)
      }
    }
  }

  const fallback = Date.now()
  for (const n of nodes) {
    if (!tsMap.has(n.id)) tsMap.set(n.id, fallback)
  }

  // Equal columns by time order (not raw ms) so sparse timestamps stay compact/centered.
  const ordered = [...new Set([...tsMap.values()].filter((v) => Number.isFinite(v)))].sort(
    (a, b) => a - b,
  )
  const rankOf = new Map(ordered.map((t, i) => [t, i]))
  const ranks = Math.max(ordered.length - 1, 1)
  const usableX = Math.min(Math.max(width * 0.48, 140), ranks * 110)
  const usableY = Math.max(height * 0.42, 80)

  const columns = new Map<number, GraphNode[]>()
  for (const n of nodes) {
    const t = tsMap.get(n.id) ?? ordered[0] ?? fallback
    n.ts = t
    const rank = rankOf.get(t) ?? 0
    const nx = ranks === 0 ? 0 : (rank / ranks - 0.5) * usableX
    n.fx = Number.isFinite(nx) ? nx : 0
    const col = columns.get(rank) || []
    col.push(n)
    columns.set(rank, col)
  }

  for (const col of columns.values()) {
    col.sort((a, b) => {
      const ka = a.kind === 'finding' || a.kind === 'group' ? 0 : 1
      const kb = b.kind === 'finding' || b.kind === 'group' ? 0 : 1
      if (ka !== kb) return ka - kb
      return a.label.localeCompare(b.label)
    })
    col.forEach((n, i) => {
      const ny =
        col.length === 1 ? 0 : ((i / (col.length - 1)) - 0.5) * usableY
      n.fy = Number.isFinite(ny) ? ny : 0
      n.x = n.fx
      n.y = n.fy
    })
  }

  return { nodes, links }
}

function linkEnds(link: GraphLink): [string, string] {
  const s = typeof link.source === 'string' ? link.source : (link.source as GraphNode).id
  const t = typeof link.target === 'string' ? link.target : (link.target as GraphNode).id
  return [s, t]
}

function neighborIds(nodeId: string, links: GraphLink[]): Set<string> {
  const out = new Set<string>([nodeId])
  for (const l of links) {
    const [s, t] = linkEnds(l)
    if (s === nodeId) out.add(t)
    if (t === nodeId) out.add(s)
  }
  return out
}

function drawPersonIcon(ctx: CanvasRenderingContext2D, x: number, y: number, s: number) {
  const r = s * 0.22
  ctx.beginPath()
  ctx.arc(x, y - s * 0.22, r, 0, Math.PI * 2)
  ctx.fill()
  ctx.beginPath()
  ctx.moveTo(x - s * 0.38, y + s * 0.42)
  ctx.quadraticCurveTo(x - s * 0.38, y + s * 0.02, x, y + s * 0.02)
  ctx.quadraticCurveTo(x + s * 0.38, y + s * 0.02, x + s * 0.38, y + s * 0.42)
  ctx.closePath()
  ctx.fill()
}

function drawCommitIcon(ctx: CanvasRenderingContext2D, x: number, y: number, s: number) {
  ctx.beginPath()
  ctx.moveTo(x, y - s * 0.42)
  ctx.lineTo(x, y + s * 0.42)
  ctx.lineWidth = Math.max(1.5, s * 0.12)
  ctx.stroke()
  ctx.beginPath()
  ctx.arc(x, y, s * 0.28, 0, Math.PI * 2)
  ctx.fill()
  ctx.strokeStyle = ICON_DETAIL
  ctx.lineWidth = Math.max(1, s * 0.08)
  ctx.stroke()
}

function drawTagIcon(ctx: CanvasRenderingContext2D, x: number, y: number, s: number) {
  ctx.beginPath()
  ctx.moveTo(x - s * 0.1, y - s * 0.4)
  ctx.lineTo(x + s * 0.38, y - s * 0.4)
  ctx.lineTo(x + s * 0.38, y - s * 0.05)
  ctx.lineTo(x + s * 0.05, y + s * 0.38)
  ctx.lineTo(x - s * 0.38, y - s * 0.05)
  ctx.closePath()
  ctx.fill()
  ctx.fillStyle = ICON_DETAIL
  ctx.beginPath()
  ctx.arc(x + s * 0.16, y - s * 0.22, s * 0.08, 0, Math.PI * 2)
  ctx.fill()
}

function drawReleaseIcon(ctx: CanvasRenderingContext2D, x: number, y: number, s: number) {
  ctx.beginPath()
  ctx.moveTo(x, y - s * 0.4)
  ctx.lineTo(x + s * 0.38, y - s * 0.18)
  ctx.lineTo(x + s * 0.38, y + s * 0.22)
  ctx.lineTo(x, y + s * 0.4)
  ctx.lineTo(x - s * 0.38, y + s * 0.22)
  ctx.lineTo(x - s * 0.38, y - s * 0.18)
  ctx.closePath()
  ctx.fill()
  ctx.strokeStyle = ICON_DETAIL
  ctx.lineWidth = Math.max(1, s * 0.07)
  ctx.beginPath()
  ctx.moveTo(x - s * 0.38, y - s * 0.18)
  ctx.lineTo(x, y + s * 0.02)
  ctx.lineTo(x + s * 0.38, y - s * 0.18)
  ctx.stroke()
  ctx.beginPath()
  ctx.moveTo(x, y + s * 0.02)
  ctx.lineTo(x, y + s * 0.4)
  ctx.stroke()
}

function drawWorkflowIcon(ctx: CanvasRenderingContext2D, x: number, y: number, s: number) {
  ctx.beginPath()
  ctx.arc(x, y, s * 0.42, 0, Math.PI * 2)
  ctx.fill()
  ctx.fillStyle = ICON_DETAIL
  ctx.beginPath()
  ctx.moveTo(x - s * 0.12, y - s * 0.22)
  ctx.lineTo(x + s * 0.26, y)
  ctx.lineTo(x - s * 0.12, y + s * 0.22)
  ctx.closePath()
  ctx.fill()
}

function drawEntityIcon(
  ctx: CanvasRenderingContext2D,
  kind: GraphEntity,
  x: number,
  y: number,
  scale: number,
) {
  const s = 16 / Math.max(scale, 0.75)
  ctx.save()
  ctx.fillStyle = ENTITY_COLOR[kind]
  ctx.strokeStyle = ENTITY_COLOR[kind]
  if (kind === 'user') drawPersonIcon(ctx, x, y, s)
  else if (kind === 'commit') drawCommitIcon(ctx, x, y, s)
  else if (kind === 'tag') drawTagIcon(ctx, x, y, s)
  else if (kind === 'release') drawReleaseIcon(ctx, x, y, s)
  else drawWorkflowIcon(ctx, x, y, s)
  ctx.restore()
}

export function CorrelationGraph({
  focus,
  related,
  pinB,
  onSelect,
  onPin,
}: {
  focus: Finding
  related: RelatedResponse
  pinB: number | null
  onSelect: (id: number) => void
  onPin: (id: number) => void
}) {
  const canvasRef = useRef<HTMLDivElement>(null)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const fgRef = useRef<any>(null)
  const [size, setSize] = useState({ w: 360, h: 280 })
  const facets = useMemo(() => availableFacets(related), [related])
  const [enabled, setEnabled] = useState<Set<GraphEntity>>(() => defaultEnabled(facets))
  const [emphasisId, setEmphasisId] = useState<string | null>(null)
  const [expandedRules, setExpandedRules] = useState<Set<string>>(() => new Set())

  useEffect(() => {
    setEnabled(defaultEnabled(availableFacets(related)))
    setEmphasisId(null)
    setExpandedRules(new Set())
  }, [focus.id, related])

  const data = useMemo(() => {
    const graph = buildGraph(focus, related, pinB, enabled, expandedRules)
    return applyTimelineLayout(graph, size.w, size.h)
  }, [focus, related, pinB, enabled, expandedRules, size.w, size.h])

  const hot = useMemo(
    () => (emphasisId ? neighborIds(emphasisId, data.links) : null),
    [emphasisId, data.links],
  )

  useEffect(() => {
    const el = canvasRef.current
    if (!el) return
    const ro = new ResizeObserver((entries) => {
      const rect = entries[0]?.contentRect
      if (!rect) return
      const w = Math.max(200, Math.floor(rect.width))
      const h = Math.max(180, Math.floor(rect.height))
      setSize((prev) => (prev.w === w && prev.h === h ? prev : { w, h }))
    })
    ro.observe(el)
    setSize({
      w: Math.max(200, el.clientWidth || 360),
      h: Math.max(180, el.clientHeight || 280),
    })
    return () => ro.disconnect()
  }, [])

  useEffect(() => {
    const fg = fgRef.current
    if (!fg || !data.links.length) return
    fg.d3Force('charge')?.strength(-80)
    fg.d3Force('link')?.distance(60)
    fg.d3Force('center')?.strength(0.01)
    fg.d3ReheatSimulation()
    const t = window.setTimeout(() => {
      fg.zoomToFit?.(80, 56)
    }, 120)
    return () => window.clearTimeout(t)
  }, [data, size.w, size.h])

  useEffect(() => {
    const api = {
      nodes: () => data.nodes as GraphNode[],
      screenOf: (id: string) => {
        const fg = fgRef.current as {
          graph2ScreenCoords?: (x: number, y: number) => { x: number; y: number }
        } | null
        const live = (fg as { graphData?: () => { nodes: GraphNode[] } } | null)?.graphData?.()
          ?.nodes
        const node =
          live?.find((n) => n.id === id) ||
          data.nodes.find((n) => n.id === id)
        if (!node) return null
        const x = node.x ?? node.fx
        const y = node.y ?? node.fy
        if (x == null || y == null) return null
        if (fg?.graph2ScreenCoords) return fg.graph2ScreenCoords(x, y)
        return { x: x + size.w / 2, y: y + size.h / 2 }
      },
    }
    ;(window as unknown as { __correlationGraph?: typeof api }).__correlationGraph = api
    return () => {
      delete (window as unknown as { __correlationGraph?: typeof api }).__correlationGraph
    }
  }, [data, size.w, size.h])

  function toggleFacet(facet: GraphEntity) {
    setEnabled((prev) => {
      const next = new Set(prev)
      if (next.has(facet)) {
        if (next.size <= 1) return prev
        next.delete(facet)
      } else {
        next.add(facet)
      }
      return next
    })
    setEmphasisId(null)
  }

  if (facets.length === 0) {
    return (
      <div className="empty">
        No 1-hop correlation via commit / release / tag / user / workflow.
        <br />
        (Repo-only links are hidden in graph view.)
      </div>
    )
  }

  return (
    <div className="graph-wrap">
      <div className="graph-toolbar">
        <div className="graph-hint">
          Left → right by finding time · same rule stacks as ×N · hub isolates path · Alt-click pins B
        </div>
        <div className="facet-toggles" aria-label="Correlation facets">
          {facets.map((facet) => (
            <button
              key={facet}
              type="button"
              className={`facet-chip ${facet}${enabled.has(facet) ? ' on' : ''}`}
              onClick={() => toggleFacet(facet)}
              title={
                BROAD_FACETS.includes(facet)
                  ? `${facet} (broad — often creates a star)`
                  : `Show/hide ${facet} hub`
              }
            >
              <i className={`facet-ico ${facet}`} />
              {facet}
            </button>
          ))}
          {emphasisId ? (
            <button type="button" className="facet-chip" onClick={() => setEmphasisId(null)}>
              Clear focus
            </button>
          ) : null}
          {expandedRules.size > 0 ? (
            <button
              type="button"
              className="facet-chip on"
              onClick={() => setExpandedRules(new Set())}
            >
              Collapse groups
            </button>
          ) : null}
        </div>
      </div>
      {data.links.length === 0 ? (
        <div className="empty" style={{ padding: '1rem' }}>
          No links for the selected facets. Turn another facet on.
        </div>
      ) : (
        <div className="graph-canvas" ref={canvasRef}>
        <ForceGraph2D
          key={`${focus.id}-${[...enabled].sort().join(',')}-${[...expandedRules].sort().join(',')}`}
          ref={fgRef}
          graphData={data}
          width={size.w}
          height={size.h}
          backgroundColor={CANVAS_BG}
          nodeId="id"
          linkColor={(link) => {
            const l = link as GraphLink
            const [s, t] = linkEnds(l)
            const dim = hot && !hot.has(s) && !hot.has(t)
            const base = FACET_LINK[l.facet] || '#6e7681'
            return dim ? 'rgba(110,118,129,0.2)' : base
          }}
          linkWidth={(link) => {
            const l = link as GraphLink
            const [s, t] = linkEnds(l)
            if (hot && (hot.has(s) || hot.has(t)) && (s === emphasisId || t === emphasisId)) {
              return 2.4
            }
            return 1.4
          }}
          cooldownTicks={100}
          onNodeClick={(node, event) => {
            const n = node as GraphNode
            if (n.kind === 'group' && n.ruleId) {
              setExpandedRules((prev) => new Set(prev).add(n.ruleId!))
              setEmphasisId(null)
              return
            }
            if (n.kind === 'finding' && n.findingId != null) {
              if (event.altKey) {
                onPin(n.findingId)
                return
              }
              onSelect(n.findingId)
              return
            }
            setEmphasisId((cur) => (cur === n.id ? null : n.id))
          }}
          nodeCanvasObject={(node, ctx, globalScale) => {
            const n = node as GraphNode
            const x = n.x || 0
            const y = n.y || 0
            const dim = Boolean(hot && !hot.has(n.id))
            ctx.globalAlpha = dim ? 0.18 : 1
            const fontSize = Math.max(10 / globalScale, 2.6)

            if (n.kind === 'finding') {
              const r = n.isFocus ? 8 : 6
              ctx.beginPath()
              ctx.arc(x, y, r, 0, 2 * Math.PI)
              ctx.fillStyle = SEV_COLOR[n.severity || 'low']
              ctx.fill()
              ctx.lineWidth = (n.isFocus || n.isPinned ? 2.4 : 1.2) / globalScale
              ctx.strokeStyle = n.isFocus
                ? '#3fb950'
                : n.isPinned
                  ? '#a371f7'
                  : CANVAS_BG
              ctx.stroke()
            } else if (n.kind === 'group') {
              const r = 11
              ctx.beginPath()
              ctx.arc(x + 2.2 / globalScale, y + 2.2 / globalScale, r, 0, 2 * Math.PI)
              ctx.fillStyle = SEV_COLOR[n.severity || 'low']
              ctx.globalAlpha = dim ? 0.1 : 0.35
              ctx.fill()
              ctx.globalAlpha = dim ? 0.18 : 1
              ctx.beginPath()
              ctx.arc(x, y, r, 0, 2 * Math.PI)
              ctx.fillStyle = SEV_COLOR[n.severity || 'low']
              ctx.fill()
              ctx.lineWidth = 2 / globalScale
              ctx.strokeStyle = CANVAS_BG
              ctx.stroke()
              ctx.fillStyle = ICON_DETAIL
              ctx.font = `bold ${Math.max(11 / globalScale, 3)}px "IBM Plex Sans", sans-serif`
              ctx.textAlign = 'center'
              ctx.textBaseline = 'middle'
              ctx.fillText(String(n.count || ''), x, y)
            } else {
              const kind = n.kind as GraphEntity
              drawEntityIcon(ctx, kind, x, y, globalScale)
              if (emphasisId === n.id) {
                ctx.beginPath()
                ctx.arc(x, y, 14 / Math.max(globalScale, 0.75), 0, Math.PI * 2)
                ctx.strokeStyle = ENTITY_COLOR[kind]
                ctx.lineWidth = 2 / globalScale
                ctx.stroke()
              }
            }

            ctx.font = `${fontSize}px "IBM Plex Sans", sans-serif`
            ctx.textAlign = 'center'
            ctx.textBaseline = 'top'
            ctx.fillStyle = CANVAS_INK
            const max = n.kind === 'group' ? 26 : n.kind === 'finding' ? 20 : 22
            const labelY = n.kind === 'group' ? 14 : n.kind === 'finding' ? 9 : 12
            ctx.fillText(shortLabel(n.label, max), x, y + labelY)
            ctx.globalAlpha = 1
          }}
          nodePointerAreaPaint={(node, color, ctx) => {
            const n = node as GraphNode
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.arc(n.x || 0, n.y || 0, n.kind === 'group' ? 16 : 14, 0, 2 * Math.PI)
            ctx.fill()
          }}
        />
        </div>
      )}
      <div className="graph-legend">
        <span><i className="lg-dot critical" /> critical</span>
        <span><i className="lg-dot high" /> high</span>
        <span><i className="lg-dot medium" /> medium</span>
        <span><i className="lg-dot low" /> low</span>
        <span><i className="lg-stack" /> same rule ×N</span>
        <span><i className="facet-ico commit" /> commit</span>
        <span><i className="facet-ico tag" /> tag</span>
        <span><i className="facet-ico release" /> release</span>
        <span><i className="facet-ico user" /> user</span>
        <span><i className="facet-ico workflow" /> workflow</span>
      </div>
    </div>
  )
}
