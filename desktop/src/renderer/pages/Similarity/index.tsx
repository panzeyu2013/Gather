import React, { useState, useEffect, useRef, useCallback, useMemo, memo } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { similarityApi, type SimilarityResult } from '../../api/similarity'
import { imageApi } from '../../api/image'
import { jobsApi } from '../../api/jobs'
import { useSimilarityStore } from '../../stores/similarityStore'
import { useEvent } from '../../hooks/useEvent'
import type { JobProgressData } from '@gather/shared'
import ProgressBar from '../../components/ProgressBar/ProgressBar'
import WritebackReport from '../../components/WritebackReport/WritebackReport'
import { useToastStore } from '../../components/Toast/ToastStore'
import { useTranslation } from '../../locales'
import { translateError } from '../../utils/errors'
import { translatePhase } from '../../utils/progress'
import type { SimilarityGroup, WritebackItem, WritebackPreview, WritebackResult, MetadataSyncSummary } from '@gather/shared'
import { captureOneApi, type C1SyncStateView } from '../../api/captureOne'
import {
  deriveSyncControls,
  deriveSyncControlHints,
  syncStatusCopy,
} from '../../utils/c1-sync-controls'
import styles from './Similarity.module.css'

// Windowing constants for the group grid. The card grid is virtualized with a
// fixed-height estimate per card (collapsed cards are constant-height; expanded
// cards add an estimated member area based on the CSS grid layout), so only the
// visible cards + overscan are mounted at once.
const GROUP_MIN_COL_WIDTH = 280
const GROUP_CARD_GAP = 16
const GROUP_HEADER_HEIGHT = 90
const TRUNCATED_MEMBER_LIMIT = 24
const MEMBER_CELL_MIN_WIDTH = 100
const MEMBER_CELL_GAP = 8
const MEMBER_AREA_PADDING = 16
const MEMBER_TOGGLE_HEIGHT = 54
const GRID_OVERSCAN = 600

function estimateGroupCardHeight(
  group: SimilarityGroup,
  expanded: boolean,
  showAllMembers: boolean,
  cardWidth: number,
): number {
  if (!expanded) return GROUP_HEADER_HEIGHT
  const memberWidth = Math.max(0, cardWidth - 2 - MEMBER_AREA_PADDING)
  const perRow = Math.max(
    1,
    Math.floor((memberWidth + MEMBER_CELL_GAP) / (MEMBER_CELL_MIN_WIDTH + MEMBER_CELL_GAP)),
  )
  const visibleCount = showAllMembers
    ? group.images.length
    : Math.min(TRUNCATED_MEMBER_LIMIT, group.images.length)
  const rows = Math.max(1, Math.ceil(visibleCount / perRow))
  const cellHeight = Math.max(0, (memberWidth - (perRow - 1) * MEMBER_CELL_GAP) / perRow)
  const memberArea = MEMBER_AREA_PADDING + rows * cellHeight + (rows - 1) * MEMBER_CELL_GAP
  const toggle = group.images.length > TRUNCATED_MEMBER_LIMIT ? MEMBER_TOGGLE_HEIGHT : 0
  return GROUP_HEADER_HEIGHT + memberArea + toggle
}

function ThumbnailImage({ path, className }: { path: string; className?: string }) {
  const [failed, setFailed] = useState(false)
  const lastPathRef = useRef(path)
  // A memoized parent (GroupCard) can reuse this instance for a different
  // path after a recluster/tier switch; a stale `failed` flag must not carry
  // over, otherwise a valid image keeps showing the placeholder.
  if (lastPathRef.current !== path) {
    lastPathRef.current = path
    setFailed(false)
  }
  const filename = path.split(/[/\\]/).pop() ?? path
  if (failed) {
    return <div className={className ? `${className} ${styles.thumbPlaceholder}` : styles.thumbPlaceholder} />
  }
  return (
    <img
      src={imageApi.thumbnailUrl(path, 256)}
      alt={filename}
      loading="lazy"
      className={className}
      onError={() => setFailed(true)}
    />
  )
}

// Subscribes only to the high-frequency progress fields so a progress tick
// re-renders just the progress bar, not the whole analysis panel.
function AnalysisProgress() {
  const progressCurrent = useSimilarityStore((s) => s.progressCurrent)
  const progressTotal = useSimilarityStore((s) => s.progressTotal)
  const progressMessage = useSimilarityStore((s) => s.progressMessage)
  return (
    <ProgressBar
      value={progressCurrent}
      max={progressTotal}
      label={translatePhase(progressMessage)}
    />
  )
}

function AnalysisPanel({
  sessionId,
  result,
  onResultAdopted,
}: {
  sessionId: string
  result: SimilarityResult | null
  onResultAdopted: () => void
}) {
  const queryClient = useQueryClient()
  const { t } = useTranslation()
  // Per-field selectors: only low-frequency fields here; progress is read by
  // the dedicated AnalysisProgress component so ticks don't re-render the panel.
  const threshold = useSimilarityStore((s) => s.threshold)
  const minGroupSize = useSimilarityStore((s) => s.minGroupSize)
  const groupingMode = useSimilarityStore((s) => s.groupingMode)
  const isAnalyzing = useSimilarityStore((s) => s.isAnalyzing)
  const setThreshold = useSimilarityStore((s) => s.setThreshold)
  const setMinGroupSize = useSimilarityStore((s) => s.setMinGroupSize)
  const setGroupingMode = useSimilarityStore((s) => s.setGroupingMode)
  const setIsAnalyzing = useSimilarityStore((s) => s.setIsAnalyzing)
  const setProgress = useSimilarityStore((s) => s.setProgress)

  const cancelMutation = useMutation({
    mutationFn: () => similarityApi.cancel(sessionId),
    onSuccess: () => setIsAnalyzing(false),
    onError: () => setIsAnalyzing(false),
  })

  const analyzeMutation = useMutation({
    mutationFn: () => similarityApi.analyze(
      sessionId,
      threshold,
      minGroupSize,
      groupingMode,
    ),
    onSuccess: () => {
      setIsAnalyzing(false)
      queryClient.invalidateQueries({ queryKey: ['similarity', sessionId] })
    },
    onError: () => {
      setIsAnalyzing(false)
    },
  })

  // On mount, detect an in-flight similarity analysis (e.g. after a renderer
  // reload) so the analyzing state and progress bar are restored.
  useEffect(() => {
    let disposed = false
    void (async () => {
      try {
        const jobs = await jobsApi.list()
        if (disposed) return
        const job = jobs.find(
          (candidate) =>
            candidate.type === 'similarity.analyze' &&
            candidate.scopeType === 'session' &&
            candidate.scopeId === sessionId &&
            ['queued', 'running', 'cancelling'].includes(candidate.status),
        )
        if (job) {
          setIsAnalyzing(true)
          setProgress(job.progressCurrent, job.progressTotal, job.progressMessage || 'similarity.analyzing')
        }
      } catch {
        // Best-effort; push events will carry subsequent progress.
      }
    })()
    return () => {
      disposed = true
    }
  }, [sessionId, setProgress, setIsAnalyzing])

  // Push-based progress from the JobService (jobs:progress). The subscription
  // stays active for the whole session so a reload mid-analysis keeps receiving
  // progress; filtering happens in the callback. Terminal frames carry the
  // final status and clear the analyzing state (mount-time recovery would
  // otherwise be stuck forever, since the invoking mutation is gone after a
  // reload).
  useEvent('jobs:progress', (payload) => {
    const data = payload as JobProgressData
    if (
      data.jobType === 'similarity.analyze' &&
      data.scopeType === 'session' &&
      data.scopeId === sessionId
    ) {
      if (data.status) {
        setIsAnalyzing(false)
        if (data.status === 'succeeded') {
          queryClient.invalidateQueries({ queryKey: ['similarity', sessionId] })
        }
        return
      }
      setProgress(data.current, data.total, data.phase || data.message || 'similarity.analyzing')
    }
  }, Boolean(sessionId))

  const reclusterMutation = useMutation({
    mutationFn: () => similarityApi.recluster(
      sessionId,
      threshold,
      minGroupSize,
      groupingMode,
    ),
    onSuccess: (data) => {
      queryClient.setQueryData(['similarity', sessionId], data)
      onResultAdopted()
    },
  })

  const handleAnalyze = () => {
    setIsAnalyzing(true)
    analyzeMutation.mutate()
  }

  // The result records the parameters it was actually computed with (validation
  // may clamp or default them). Sync the store only when a NEW result object
  // arrives, so draft slider edits are never overwritten by a stale result.
  // Tier rows record the analyze-time minGroupSize/groupingMode, so when the
  // result is precomputed only the threshold is synced; the minGroupSize and
  // groupingMode stay whatever the user drafted.
  const lastSyncedResult = useRef<SimilarityResult | null>(null)
  useEffect(() => {
    if (!result || result === lastSyncedResult.current) return
    lastSyncedResult.current = result
    if (result.stats.threshold != null) {
      setThreshold(result.stats.threshold)
    }
    if (!result.stats.precomputed) {
      if (result.stats.minGroupSize != null) {
        setMinGroupSize(result.stats.minGroupSize)
      }
      if (result.stats.groupingMode) {
        setGroupingMode(result.stats.groupingMode)
      }
    }
  }, [result, setThreshold, setMinGroupSize, setGroupingMode])

  // Dragging the threshold slider switches to a precomputed neighbor tier
  // (saved during analyze/recluster) instead of re-running clustering. If no
  // tier exists for the draft value the request returns null and the draft is
  // kept untouched; the user can still hit "重新聚类".
  const tierRequestRef = useRef(0)
  useEffect(() => {
    if (!result) return
    if (threshold === result.stats.threshold) return
    const timer = setTimeout(() => {
      const requestId = ++tierRequestRef.current
      void (async () => {
        try {
          const tierResult = await similarityApi.getResult(sessionId, threshold)
          // Guard against a stale tier response overwriting a newer draft:
          // only adopt when the resolved row matches the requested threshold
          // and no newer request has been issued since.
          if (
            tierResult &&
            tierResult.stats.threshold === threshold &&
            tierRequestRef.current === requestId
          ) {
            queryClient.setQueryData(['similarity', sessionId], tierResult)
            // The adopted tier has its own group set; selections made against
            // the previous result must not leak into it.
            onResultAdopted()
          }
        } catch {
          // No precomputed tier (or a transient failure): keep the draft value.
        }
      })()
    }, 300)
    return () => clearTimeout(timer)
  }, [threshold, result, sessionId, queryClient, onResultAdopted])

  return (
    <div className={styles.panel}>
      <h2 className={styles.panelTitle}>{t('similarity.analysisControl')}</h2>

      <div className={styles.controlRow}>
        <span className={styles.controlLabel}>{t('similarity.groupingScope')}</span>
        <div className={styles.modeSelector}>
          <button
            className={groupingMode === 'sequential' ? styles.modeActive : styles.modeButton}
            aria-pressed={groupingMode === 'sequential'}
            onClick={() => setGroupingMode('sequential')}
          >
            <strong>{t('similarity.sequentialGrouping')}</strong>
            <span>{t('similarity.sequentialGroupingHint')}</span>
          </button>
          <button
            className={groupingMode === 'global' ? styles.modeActive : styles.modeButton}
            aria-pressed={groupingMode === 'global'}
            onClick={() => setGroupingMode('global')}
          >
            <strong>{t('similarity.globalGrouping')}</strong>
            <span>{t('similarity.globalGroupingHint')}</span>
          </button>
        </div>
      </div>

      <div className={styles.controlRow}>
        <label className={styles.controlLabel} htmlFor="similarity-threshold">
          {t('similarity.thresholdLabel')}<strong>{threshold}</strong>
        </label>
        <input
          id="similarity-threshold"
          type="range"
          min={0}
          max={30}
          value={threshold}
          onChange={(e) => setThreshold(Number(e.target.value))}
          className={styles.slider}
        />
        <span className={styles.rangeHint}>{t('similarity.thresholdRangeHint')}</span>
      </div>

      <div className={styles.controlRow}>
        <label className={styles.controlLabel} htmlFor="similarity-min-group-size">
          {t('similarity.minGroupSizeLabel')}<strong>{minGroupSize}</strong>
        </label>
        <input
          id="similarity-min-group-size"
          type="range"
          min={2}
          max={10}
          value={minGroupSize}
          onChange={(e) => setMinGroupSize(Number(e.target.value))}
          className={styles.slider}
        />
      </div>

      <div className={styles.controlActions}>
        <button
          className={styles.analyzeBtn}
          onClick={handleAnalyze}
          disabled={isAnalyzing || analyzeMutation.isPending}
        >
          {isAnalyzing || analyzeMutation.isPending ? t('similarity.analyzing') : t('similarity.startAnalyze')}
        </button>

        {result && (
          <button
            className={styles.reclusterBtn}
            onClick={() => reclusterMutation.mutate()}
            disabled={reclusterMutation.isPending}
          >
            {reclusterMutation.isPending ? t('similarity.clustering') : t('similarity.recluster')}
          </button>
        )}
      </div>

      {(isAnalyzing || analyzeMutation.isPending) && (
        <div className={styles.progressSection}>
          <AnalysisProgress />
          <button
            className={styles.cancelBtn}
            onClick={() => cancelMutation.mutate()}
            disabled={cancelMutation.isPending}
          >
            {t('similarity.cancelAnalysis')}
          </button>
        </div>
      )}

      {analyzeMutation.isError && (
        <p className={styles.error}>
          {t('similarity.error', { message: translateError(analyzeMutation.error) })}
        </p>
      )}

      {result && result.stats && (
        <div className={styles.stats}>
          <span>{t('similarity.groupsCount', { count: result.stats.totalGroups })}</span>
          <span>{t('similarity.ungroupedCount', { count: result.stats.totalUngrouped })}</span>
          <span>{t('similarity.thresholdValue', { threshold: result.stats.threshold })}</span>
          <span>
            {result.stats.groupingMode === 'sequential' ? t('similarity.sequentialGrouping') : t('similarity.globalGrouping')}
          </span>
        </div>
      )}
    </div>
  )
}

const GroupCard = memo(function GroupCard({
  group,
  selected,
  onSelectedChange,
  expanded,
  onToggleExpanded,
  showAllMembers,
  onToggleShowAll,
}: {
  group: SimilarityGroup
  selected: boolean
  onSelectedChange: (groupId: number, selected: boolean) => void
  expanded: boolean
  onToggleExpanded: (groupId: number) => void
  showAllMembers: boolean
  onToggleShowAll: (groupId: number) => void
}) {
  const { t } = useTranslation()
  const rep = group.images.find((img) => img.representative) ?? group.images[0]
  const visibleMembers = showAllMembers
    ? group.images
    : group.images.slice(0, TRUNCATED_MEMBER_LIMIT)
  const hasMoreMembers = group.images.length > TRUNCATED_MEMBER_LIMIT

  return (
    <div className={styles.groupCard}>
      <div className={styles.groupHeaderRow}>
        <input
          type="checkbox"
          checked={selected}
          onChange={(event) => onSelectedChange(group.id, event.target.checked)}
          onClick={(event) => event.stopPropagation()}
          aria-label={t('similarity.selectGroup', { label: group.label })}
          className={styles.groupCheckbox}
        />
        <button
          type="button"
          className={styles.groupExpand}
          onClick={() => onToggleExpanded(group.id)}
          aria-expanded={expanded}
        >
          <ThumbnailImage path={rep.path} className={styles.groupThumb} />
          <span className={styles.groupInfo}>
            <span className={styles.groupLabel}>{group.label}</span>
            <span className={styles.groupCount}>{t('similarity.groupCount', { count: group.count })}</span>
          </span>
          <span aria-hidden="true" className={styles.expandIcon}>{expanded ? '▾' : '▸'}</span>
        </button>
      </div>

      {expanded && (
        <div className={styles.groupMembers}>
          {visibleMembers.map((img) => (
            <div key={img.path} className={styles.memberItem}>
              <ThumbnailImage path={img.path} className={styles.memberThumb} />
              <span className={styles.memberName}>
                {img.path.split(/[/\\]/).pop() ?? img.path}
              </span>
            </div>
          ))}
        </div>
      )}

      {expanded && hasMoreMembers && (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0' }}>
          <button
            type="button"
            className={styles.reclusterBtn}
            onClick={() => onToggleShowAll(group.id)}
          >
            {showAllMembers ? '收起' : `显示全部 (共 ${group.images.length} 张)`}
          </button>
        </div>
      )}
    </div>
  )
})

// Windowed group grid: only the cards intersecting the scroll viewport (plus
// overscan) are mounted. Cards are laid out with the same geometry the CSS
// `auto-fill minmax(280px, 1fr)` grid would produce; the spacer div below
// provides the total scroll height. Expansion/"show all" state lives here (not
// inside GroupCard) so height estimates stay exact and the state survives cards
// being unmounted as they scroll out of view.
function GroupGrid({
  result,
  selectedGroupIds,
  onSelectedChange,
}: {
  result: SimilarityResult
  selectedGroupIds: Set<number>
  onSelectedChange: (groupId: number, selected: boolean) => void
}) {
  const { t } = useTranslation()
  const [expandedIds, setExpandedIds] = useState<Set<number>>(() => new Set())
  const [showAllIds, setShowAllIds] = useState<Set<number>>(() => new Set())
  const [scrollTop, setScrollTop] = useState(0)
  const [viewport, setViewport] = useState({ width: 0, height: 0 })
  const containerRef = useRef<HTMLDivElement>(null)
  const scrollFrameRef = useRef<number | null>(null)

  const groups = result.groups

  useEffect(() => {
    setExpandedIds(new Set())
    setShowAllIds(new Set())
    setScrollTop(0)
    if (containerRef.current) containerRef.current.scrollTop = 0
  }, [result])

  useEffect(() => {
    const element = containerRef.current
    if (!element) return
    const update = () => {
      setViewport((current) => (
        current.width === element.clientWidth && current.height === element.clientHeight
          ? current
          : { width: element.clientWidth, height: element.clientHeight }
      ))
    }
    update()
    if (typeof ResizeObserver === 'undefined') {
      window.addEventListener('resize', update)
      return () => window.removeEventListener('resize', update)
    }
    const observer = new ResizeObserver(update)
    observer.observe(element)
    return () => observer.disconnect()
  }, [result])

  useEffect(() => () => {
    if (scrollFrameRef.current !== null) {
      cancelAnimationFrame(scrollFrameRef.current)
    }
  }, [])

  const handleScroll = useCallback((event: React.UIEvent<HTMLDivElement>) => {
    const nextScrollTop = event.currentTarget.scrollTop
    if (scrollFrameRef.current !== null) cancelAnimationFrame(scrollFrameRef.current)
    scrollFrameRef.current = requestAnimationFrame(() => {
      scrollFrameRef.current = null
      setScrollTop(nextScrollTop)
    })
  }, [])

  const toggleExpanded = useCallback((groupId: number) => {
    setExpandedIds((current) => {
      const next = new Set(current)
      if (next.has(groupId)) next.delete(groupId)
      else next.add(groupId)
      return next
    })
  }, [])

  const toggleShowAll = useCallback((groupId: number) => {
    setShowAllIds((current) => {
      const next = new Set(current)
      if (next.has(groupId)) next.delete(groupId)
      else next.add(groupId)
      return next
    })
  }, [])

  // Same track-count formula the CSS `auto-fill minmax(280px, 1fr)` grid uses,
  // so absolute card placement matches the visual layout exactly.
  const cols = Math.max(
    1,
    Math.floor((viewport.width + GROUP_CARD_GAP) / (GROUP_MIN_COL_WIDTH + GROUP_CARD_GAP)),
  )
  const cardWidth = (viewport.width - (cols - 1) * GROUP_CARD_GAP) / cols

  const { rows, totalHeight } = useMemo(() => {
    const rowModels: { top: number; height: number; cards: { group: SimilarityGroup; index: number }[] }[] = []
    let top = 0
    for (let start = 0; start < groups.length; start += cols) {
      const cards: { group: SimilarityGroup; index: number }[] = []
      let rowHeight = 0
      for (let offset = 0; offset < cols && start + offset < groups.length; offset += 1) {
        const group = groups[start + offset]
        cards.push({ group, index: start + offset })
        rowHeight = Math.max(
          rowHeight,
          estimateGroupCardHeight(
            group,
            expandedIds.has(group.id),
            showAllIds.has(group.id),
            cardWidth,
          ),
        )
      }
      rowModels.push({ top, height: rowHeight, cards })
      top += rowHeight + GROUP_CARD_GAP
    }
    return { rows: rowModels, totalHeight: Math.max(0, top - GROUP_CARD_GAP) }
  }, [groups, cols, cardWidth, expandedIds, showAllIds])

  const visibleRows = useMemo(() => {
    const overscan = Math.max(GRID_OVERSCAN, viewport.height)
    const visibleTop = Math.max(0, scrollTop - overscan)
    const visibleBottom = scrollTop + viewport.height + overscan
    return rows.filter((row) => (
      row.top + row.height >= visibleTop && row.top <= visibleBottom
    ))
  }, [rows, scrollTop, viewport.height])

  useEffect(() => {
    const maximum = Math.max(0, totalHeight - viewport.height)
    if (scrollTop <= maximum) return
    if (containerRef.current) containerRef.current.scrollTop = maximum
    setScrollTop(maximum)
  }, [totalHeight, viewport.height, scrollTop])

  if (groups.length === 0) {
    return (
      <div className={styles.empty}>
        <p>{t('similarity.noGroups')}</p>
      </div>
    )
  }

  return (
    <div
      ref={containerRef}
      onScroll={handleScroll}
      style={{ position: 'relative', maxHeight: '70vh', overflowY: 'auto' }}
    >
      <div style={{ position: 'relative', height: totalHeight }}>
        {visibleRows.map((row) => (
          row.cards.map(({ group, index }) => (
            <div
              key={group.id}
              style={{
                position: 'absolute',
                top: row.top,
                left: (index % cols) * (cardWidth + GROUP_CARD_GAP),
                width: cardWidth,
              }}
            >
              <GroupCard
                group={group}
                selected={selectedGroupIds.has(group.id)}
                onSelectedChange={onSelectedChange}
                expanded={expandedIds.has(group.id)}
                onToggleExpanded={toggleExpanded}
                showAllMembers={showAllIds.has(group.id)}
                onToggleShowAll={toggleShowAll}
              />
            </div>
          ))
        ))}
      </div>
    </div>
  )
}

function KeywordWritebackPanel({
  sessionId,
  result,
  selectedGroupIds,
  onSelectAll,
}: {
  sessionId: string
  result: SimilarityResult
  selectedGroupIds: Set<number>
  onSelectAll: (selected: boolean) => void
}) {
  const [keywordInput, setKeywordInput] = useState('')
  const [preview, setPreview] = useState<WritebackPreview | null>(null)
  const [writebackResult, setWritebackResult] = useState<WritebackResult | null>(null)
  const [failedItems, setFailedItems] = useState<WritebackItem[]>([])
  const [message, setMessage] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  // Session-level sync state machine view (2.3.5 P1): button availability and
  // status copy are both driven by it.
  const [syncView, setSyncView] = useState<C1SyncStateView | null>(null)
  const addToast = useToastStore((s) => s.addToast)
  const { t } = useTranslation()

  const refreshSyncState = useCallback(async () => {
    try {
      setSyncView(await captureOneApi.syncState(sessionId))
    } catch {
      // 保留上次视图；未知状态下按钮按保守策略全部禁用。
    }
  }, [sessionId])

  // 挂载时拉取一次（写回协调器事件会持续刷新视图）。
  useEffect(() => {
    void refreshSyncState()
  }, [refreshSyncState])

  // 协调器每次 emitSummary 后重拉视图：写回行异步推进（pending/writing → written
  // → synced），状态机文案随之更新。
  useEvent('culling:sync-status', (payload) => {
    const summary = payload as MetadataSyncSummary
    if (summary.sessionId !== sessionId) return
    void refreshSyncState()
  }, Boolean(sessionId))

  const keywords = keywordInput
    .split(/[,，]/)
    .map(keyword => keyword.trim())
    .filter(Boolean)
  const assignments = [...selectedGroupIds].map(groupId => ({ groupId, keywords }))
  const canPreview = assignments.length > 0 && keywords.length > 0 && !busy

  useEffect(() => {
    setPreview(null)
    setWritebackResult(null)
    setFailedItems([])
    setSyncView(null)
  }, [keywordInput, selectedGroupIds])

  const handlePreview = async () => {
    if (!canPreview) return
    setBusy(true)
    setMessage(null)
    try {
      const nextPreview = await similarityApi.previewWriteback(
        sessionId,
        assignments,
        result.stats.threshold,
      )
      setPreview(nextPreview)
      setMessage(t('similarity.previewMessage', { count: nextPreview.affectedPhotos }))
    } catch (error) {
      setMessage(t('similarity.previewFailed', { message: translateError(error) }))
    } finally {
      setBusy(false)
    }
  }

  const handleWriteback = async () => {
    if (!canPreview) return
    setBusy(true)
    setMessage(null)
    try {
      const currentPreview = preview ?? await similarityApi.previewWriteback(
        sessionId,
        assignments,
        result.stats.threshold,
      )
      setPreview(currentPreview)
      const nextResult = await similarityApi.writeback(
        sessionId,
        currentPreview.items,
        result.stats.threshold,
      )
      setWritebackResult(nextResult)
      setFailedItems(nextResult.failedItems)
      setMessage(t('similarity.writebackDone', { written: nextResult.written, failed: nextResult.failed, skipped: nextResult.skipped }))
    } catch (error) {
      setMessage(t('similarity.writebackFailed', { message: translateError(error) }))
    } finally {
      setBusy(false)
      void refreshSyncState()
    }
  }

  const handleRetry = async () => {
    setBusy(true)
    try {
      const nextResult = await similarityApi.retryFailedWriteback(sessionId)
      setWritebackResult(nextResult)
      setFailedItems(nextResult.failedItems)
      setMessage(t('similarity.retryDone', { written: nextResult.written, failed: nextResult.failed }))
    } catch (error) {
      setMessage(t('similarity.retryFailed', { message: translateError(error) }))
    } finally {
      setBusy(false)
      void refreshSyncState()
    }
  }

  const handleConfirmSync = async () => {
    try {
      await similarityApi.confirmSync(sessionId)
      setMessage(t('similarity.confirmSyncDone'))
    } catch (error) {
      setMessage(t('similarity.confirmFailed', { message: translateError(error) }))
    } finally {
      void refreshSyncState()
    }
  }

  const handleCleanup = async () => {
    try {
      const cleanup = await similarityApi.cleanup(sessionId)
      setMessage(t('similarity.cleanupDone', { count: cleanup.deletedCount }))
      setWritebackResult(null)
      setFailedItems([])
      setPreview(null)
    } catch (error) {
      setMessage(t('similarity.cleanupFailed', { message: translateError(error) }))
    } finally {
      void refreshSyncState()
    }
  }

  const handleReloadMetadata = async () => {
    setBusy(true)
    try {
      await window.gather.reloadMetadata(sessionId)
      setMessage(t('similarity.reloadDone'))
    } catch (error) {
      addToast('error', error instanceof Error ? translateError(error) : t('similarity.loadMetadataFailed'))
    } finally {
      setBusy(false)
      void refreshSyncState()
    }
  }

  const controls = deriveSyncControls({
    syncState: syncView?.state ?? null,
    hasWritten: (syncView?.xmp.written ?? 0) > 0,
    acked: (syncView?.reloadAckedAt ?? null) != null,
  })
  const hints = deriveSyncControlHints(
    syncView?.state ?? null,
    controls,
    (syncView?.reloadAckedAt ?? null) != null,
  )

  return (
    <div className={styles.writebackPanel}>
      <div className={styles.writebackHeader}>
        <div>
          <h2 className={styles.panelTitle}>{t('similarity.writebackTitle')}</h2>
          <p className={styles.writebackHint}>
            {t('similarity.writebackHint')}
          </p>
        </div>
        <label className={styles.selectAll}>
          <input
            type="checkbox"
            checked={result.groups.length > 0 && selectedGroupIds.size === result.groups.length}
            onChange={(event) => onSelectAll(event.target.checked)}
          />
          {t('similarity.selectAllGroups')}
        </label>
      </div>
      <div className={styles.keywordControls}>
        <input
          className={styles.keywordInput}
          value={keywordInput}
          onChange={(event) => setKeywordInput(event.target.value)}
          placeholder={t('similarity.keywordPlaceholder')}
          aria-label={t('similarity.keywordLabel')}
        />
        <button className={styles.reclusterBtn} disabled={!canPreview} onClick={() => void handlePreview()}>
          {t('similarity.previewBtn')}
        </button>
        <button className={styles.analyzeBtn} disabled={!canPreview} onClick={() => void handleWriteback()}>
          {busy ? t('similarity.processing') : t('similarity.writebackBtn')}
        </button>
      </div>
      <p className={styles.captureOneHint}>
        {t('similarity.captureOneHint')}
      </p>
      {message && <p className={styles.statusMessage}>{message}</p>}
      {preview && (
        <div className={styles.writebackPreview} aria-label={t('similarity.xmpPreviewLabel')}>
          {preview.items.slice(0, 50).map(item => (
            <div className={styles.writebackPreviewRow} key={item.xmpPath}>
              <strong title={item.xmpPath}>{item.xmpPath.split(/[/\\]/).pop()}</strong>
              <span>
                {(item.preview?.before.keywords ?? []).join('、') || t('similarity.noKeywords')}
                {' → '}
                {(item.preview?.after.keywords ?? item.keywords).join('、') || t('similarity.noKeywords')}
              </span>
              <small>
                {item.preview?.willCreate ? t('similarity.willCreateXmp') : t('similarity.updateXmp')}
                {(item.preview?.sharedPhotoCount ?? 1) > 1
                  ? t('similarity.sharedCount', { count: item.preview?.sharedPhotoCount })
                  : ''}
                {item.preview?.externalChanged ? t('similarity.externalConflict') : ''}
                {t('similarity.source')}
              </small>
            </div>
          ))}
          {preview.items.length > 50 && <small>{t('similarity.moreItems', { count: preview.items.length - 50 })}</small>}
        </div>
      )}
      {writebackResult && (
        <>
          <p className={styles.statusMessage}>
            <strong>{t('similarity.syncStatus')}</strong>
            {syncStatusCopy(syncView?.state ?? null)}
          </p>
          <WritebackReport
            result={writebackResult}
            failedItems={failedItems}
            onRetryFailed={() => void handleRetry()}
            onConfirmSync={() => void handleConfirmSync()}
            onCleanup={() => void handleCleanup()}
            disabled={busy}
            canConfirmSync={controls.canConfirmSync}
            canCleanup={controls.canCleanup}
            confirmHint={hints.confirmHint ?? undefined}
            cleanupHint={hints.cleanupHint ?? undefined}
          />
          <div className={styles.reloadRow}>
            <button
              className={styles.reclusterBtn}
              onClick={() => void handleReloadMetadata()}
              disabled={busy || !controls.canLoadMetadata}
              title={hints.loadHint ?? undefined}
            >
              {t('similarity.loadMetadataBtn')}
            </button>
            <span className={styles.reloadHint}>
              {controls.canLoadMetadata
                ? t('similarity.reloadHint')
                : hints.loadHint}
            </span>
          </div>
        </>
      )}
    </div>
  )
}

export default function Similarity() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const [selectedGroupIds, setSelectedGroupIds] = useState<Set<number>>(new Set())
  const resetSimilarityState = useSimilarityStore(state => state.reset)

  // Called whenever the displayed result is replaced wholesale (a precomputed
  // tier adopted from the slider, or a fresh recluster): selections made
  // against the previous group set must not leak into the new one.
  const onResultAdopted = useCallback(() => {
    setSelectedGroupIds(new Set())
  }, [])

  const onSelectedChange = useCallback((groupId: number, selected: boolean) => {
    setSelectedGroupIds((current) => {
      const next = new Set(current)
      if (selected) next.add(groupId)
      else next.delete(groupId)
      return next
    })
  }, [])

  useEffect(() => {
    setSelectedGroupIds(new Set())
    resetSimilarityState()
  }, [sessionId, resetSimilarityState])

  const {
    data: result,
    isLoading,
    error,
  } = useQuery({
    queryKey: ['similarity', sessionId],
    queryFn: () => similarityApi.getResult(sessionId!),
    enabled: !!sessionId,
    refetchInterval: (query) => {
      const data = query.state.data
      if (!data) return 2000
      return false
    },
  })

  const onSelectAll = useCallback((selected: boolean) => {
    setSelectedGroupIds(selected ? new Set((result?.groups ?? []).map((group) => group.id)) : new Set())
  }, [result])
  const { t } = useTranslation()

  if (!sessionId) {
      return <div className={styles.page}><p>{t('similarity.noWorkspace')}</p></div>
  }

  if (error) {
    return (
      <div className={styles.page}>
        <p>{t('similarity.error', { message: translateError(error) })}</p>
      </div>
    )
  }

  return (
    <div className={styles.page}>
      <h1 className={styles.title}>{t('similarity.title')}</h1>
      <AnalysisPanel
        sessionId={sessionId}
        result={result ?? null}
        onResultAdopted={onResultAdopted}
      />
      {isLoading && <p className={styles.loading}>{t('similarity.loading')}</p>}
      {result && (
        <>
          <KeywordWritebackPanel
            key={sessionId}
            sessionId={sessionId}
            result={result}
            selectedGroupIds={selectedGroupIds}
            onSelectAll={onSelectAll}
          />
          <GroupGrid
            result={result}
            selectedGroupIds={selectedGroupIds}
            onSelectedChange={onSelectedChange}
          />
        </>
      )}
    </div>
  )
}
