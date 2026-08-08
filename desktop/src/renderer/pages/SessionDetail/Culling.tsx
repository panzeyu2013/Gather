import React, {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import { useParams } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import type {
  AssetCullingState,
  CaptureOneColorLabel,
  CullingAsset,
  CullingFilters,
  CullingScope,
  CullingUpdatePatch,
  CullingUpdateResult,
  CullingHistoryOperation,
  NavigationGroup,
  MetadataConflict,
  MetadataConflictChoice,
  MetadataField,
  MetadataSyncSummary,
} from '@gather/shared'
import { cullingApi } from '../../api/culling'
import { imageApi } from '../../api/image'
import { navigationApi } from '../../api/navigation'
import { metadataApi } from '../../api/metadata'
import { qualityApi } from '../../api/quality'
import { jobsApi } from '../../api/jobs'
import { useEvent } from '../../hooks/useEvent'
import { useToastStore } from '../../components/Toast/ToastStore'
import { t as defaultT, useTranslation, type TranslationKey, type TypedTFunction } from '../../locales'
import { translateError, translateErrorCode } from '../../utils/errors'
import styles from './Culling.module.css'

/** Map the main-process navigation lead explanation code to tooltip copy
 * (design_improvements.md 4.4.2); legacy rows pass through unchanged. */
const navExplanation = (
  explanation: string | undefined,
  translator: TypedTFunction = defaultT,
): string | undefined => {
  if (!explanation) return undefined
  switch (explanation) {
    case 'NAV_RECOMMEND_QUALITY': return translator('culling.navExplanation.quality')
    case 'NAV_RECOMMEND_RATING': return translator('culling.navExplanation.rating')
    case 'NAV_RECOMMEND_ORDER': return translator('culling.navExplanation.order')
    default: return explanation
  }
}

const COLOR_LABELS: Array<{
  value: CaptureOneColorLabel
  labelKey: TranslationKey
  color: string
}> = [
  { value: 'None', labelKey: 'culling.color.none', color: '#777' },
  { value: 'Red', labelKey: 'culling.color.red', color: '#ef5350' },
  { value: 'Orange', labelKey: 'culling.color.orange', color: '#ff9800' },
  { value: 'Yellow', labelKey: 'culling.color.yellow', color: '#fdd835' },
  { value: 'Green', labelKey: 'culling.color.green', color: '#4caf50' },
  { value: 'Blue', labelKey: 'culling.color.blue', color: '#42a5f5' },
  { value: 'Pink', labelKey: 'culling.color.pink', color: '#ec407a' },
  { value: 'Purple', labelKey: 'culling.color.purple', color: '#ab47bc' },
]

interface HistoryEntry {
  operationId: number
  photoId: string
  before: Pick<AssetCullingState, 'pickState' | 'rating' | 'colorLabel'>
  after: Pick<AssetCullingState, 'pickState' | 'rating' | 'colorLabel'>
  expectedRevision: number
  fields: Array<keyof CullingUpdatePatch>
}

interface ViewTransform {
  scale: number
  x: number
  y: number
}

function syncLabel(summary: MetadataSyncSummary | undefined, translator: TypedTFunction): string {
  if (!summary || summary.items.length === 0) return translator('culling.syncLabel.synced')
  if (summary.conflict > 0) return translator('culling.syncLabel.conflict', { count: summary.conflict })
  if (summary.failed > 0) return translator('culling.syncLabel.failed', { count: summary.failed })
  if (summary.pending + summary.writing > 0) {
    return translator('culling.syncLabel.pending', { count: summary.pending + summary.writing })
  }
  if (summary.written > 0) return translator('culling.syncLabel.written', { count: summary.written })
  if (summary.synced > 0) return translator('culling.syncLabel.loaded', { count: summary.synced })
  return translator('culling.syncLabel.synced')
}

function valueLabel(value: unknown, translator: TypedTFunction): string {
  if (Array.isArray(value)) return value.join(translator('list.separator')) || translator('culling.valueLabel.empty')
  if (value === '' || value === undefined || value === null) return translator('culling.valueLabel.empty')
  return String(value)
}

function sourceLabel(asset: CullingAsset, translator: TypedTFunction): string {
  if (asset.metadataSource === 'template') return translator('culling.source.template')
  if (asset.metadataSource === 'face-keyword') return translator('culling.source.faceKeyword')
  if (asset.metadataSource === 'similarity') return translator('culling.source.similarity')
  if (asset.quality?.status === 'succeeded') return translator('culling.source.ai')
  if (asset.state.source === 'imported') return translator('culling.source.imported')
  return translator('culling.source.manual')
}

function ConflictPanel({
  sessionId,
  conflicts,
  onResolved,
}: {
  sessionId: string
  conflicts: MetadataConflict[]
  onResolved: (summary: MetadataSyncSummary) => void
}) {
  const { t } = useTranslation()
  const [choices, setChoices] = useState<Record<string, MetadataConflictChoice>>({})
  const [resolving, setResolving] = useState(false)
  const conflict = conflicts[0]
  useEffect(() => {
    if (!conflict) return
    setChoices(Object.fromEntries(conflict.fields.map(field => [field.field, 'keep_local'])))
  }, [conflict])
  if (!conflict) return null
  return (
    <section className={styles.conflictPanel}>
      <header>
        <strong>{t('culling.conflict.title')}</strong>
        <span title={conflict.xmpPath}>{conflict.xmpPath.split(/[/\\]/).pop()}</span>
      </header>
      {conflict.fields.map(field => (
        <div className={styles.conflictField} key={field.field}>
          <strong>{field.field === 'rating' ? t('culling.conflict.fieldRating') : field.field === 'label' ? t('culling.conflict.fieldLabel') : t('culling.conflict.fieldKeyword')}</strong>
          <span title={valueLabel(field.local, t)}>{t('culling.conflict.local', { value: valueLabel(field.local, t) })}</span>
          <span title={valueLabel(field.remote, t)}>{t('culling.conflict.remote', { value: valueLabel(field.remote, t) })}</span>
          <select
            value={choices[field.field] ?? 'keep_local'}
            onChange={event => setChoices(current => ({
              ...current,
              [field.field]: event.target.value as MetadataConflictChoice,
            }))}
          >
            <option value="keep_local">{t('culling.conflict.keepLocal')}</option>
            <option value="use_remote">{t('culling.conflict.useRemote')}</option>
          </select>
        </div>
      ))}
      <footer>
        <span>{conflicts.length > 1 ? t('culling.conflict.moreRemaining', { count: conflicts.length - 1 }) : t('culling.conflict.last')}</span>
        <button
          disabled={resolving}
          onClick={() => {
            setResolving(true)
            void metadataApi.resolveConflict(
              sessionId,
              conflict.xmpPath,
              choices as Partial<Record<MetadataField, MetadataConflictChoice>>,
            ).then(onResolved).finally(() => setResolving(false))
          }}
        >
          {resolving ? t('culling.conflict.resolving') : t('culling.conflict.apply')}
        </button>
      </footer>
    </section>
  )
}

function statePatch(
  state: HistoryEntry['before'],
  fields: Array<keyof CullingUpdatePatch>,
): CullingUpdatePatch {
  const patch: CullingUpdatePatch = {}
  if (fields.includes('pickState')) patch.pickState = state.pickState
  if (fields.includes('rating')) patch.rating = state.rating
  if (fields.includes('colorLabel')) patch.colorLabel = state.colorLabel
  return patch
}

function FilmThumb({ filepath, filename }: { filepath: string; filename: string }) {
  const { t } = useTranslation()
  const [broken, setBroken] = useState(false)
  if (broken) {
    return <span className={styles.thumbBroken}>{t('culling.offline')}</span>
  }
  return (
    <img
      src={imageApi.thumbnailUrl(filepath, 256)}
      alt={filename}
      loading="lazy"
      onError={() => setBroken(true)}
    />
  )
}

function CullingImage({
  asset,
  transform,
  faceAlign,
}: {
  asset: CullingAsset
  transform: ViewTransform
  faceAlign: boolean
}) {
  const [broken, setBroken] = useState(false)
  const face = asset.faceBboxes[0]
  const faceX = face ? Math.max(0, Math.min(1, face[0] + face[2] / 2)) : 0.5
  const faceY = face ? Math.max(0, Math.min(1, face[1] + face[3] / 2)) : 0.5
  const { t } = useTranslation()
  const alignX = faceAlign && face ? (0.5 - faceX) * 100 : 0
  const alignY = faceAlign && face ? (0.5 - faceY) * 100 : 0
  const scale = faceAlign && face ? Math.max(2, transform.scale) : transform.scale
  return (
    <div className={styles.compareCell}>
      {broken ? (
        <div className={styles.viewerBroken}>
          <p>{t('culling.viewerBroken')}</p>
          <p className={styles.viewerBrokenHint}>{t('culling.viewerBrokenHint')}</p>
        </div>
      ) : (
        <img
          src={imageApi.previewUrl(asset.photo.filepath, 2560)}
          alt={asset.photo.filename}
          className={styles.viewerImage}
          draggable={false}
          onError={() => setBroken(true)}
          style={{
            transform: `translate(calc(${transform.x}px + ${alignX}%), calc(${transform.y}px + ${alignY}%)) scale(${scale})`,
          }}
        />
      )}
      <div className={styles.imageCaption}>
        <span>{asset.photo.filename}</span>
        <span className={styles.sourceLabel}>{sourceLabel(asset, t)}</span>
        <span>{asset.state.rating > 0 ? `${asset.state.rating}★` : t('culling.unrated')}</span>
      </div>
      {asset.state.pickState !== 'unreviewed' && (
        <span className={`${styles.pickBadge} ${
          asset.state.pickState === 'picked' ? styles.picked : styles.rejected
        }`}>
          {asset.state.pickState === 'picked' ? t('culling.picked') : t('culling.rejected')}
        </span>
      )}
      {faceAlign && !face && <span className={styles.noFaceBadge}>{t('culling.noFace')}</span>}
      {asset.quality && (
        <span className={styles.qualityBadge} title={
          asset.quality.status === 'failed'
            ? asset.quality.errorMessage ?? t('culling.qualityFailed')
            : t('culling.qualityInfo', {
                sharpness: Math.round((asset.quality.subjectSharpness ?? asset.quality.sharpness) * 100),
                exposure: Math.round(asset.quality.exposure * 100),
              })
        }>
          {asset.quality.status === 'failed' ? t('culling.qualityFailedShort') : t('culling.qualityScore', { score: Math.round(asset.quality.score * 100) })}
          {asset.quality.warnings.length > 0 ? ' ⚠' : ''}
        </span>
      )}
    </div>
  )
}

export default function Culling() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const queryClient = useQueryClient()
  const addToast = useToastStore(state => state.addToast)
  const { t } = useTranslation()
  const [scope, setScope] = useState<CullingScope>('all')
  const [filters, setFilters] = useState<CullingFilters>({})
  const [assets, setAssets] = useState<CullingAsset[]>([])
  const [currentIndex, setCurrentIndex] = useState(0)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [autoAdvance, setAutoAdvance] = useState(true)
  const [compareCount, setCompareCount] = useState<1 | 2 | 4>(1)
  const [faceAlign, setFaceAlign] = useState(false)
  const [transform, setTransform] = useState<ViewTransform>({ scale: 1, x: 0, y: 0 })
  const [undoStack, setUndoStack] = useState<HistoryEntry[][]>([])
  const [redoStack, setRedoStack] = useState<HistoryEntry[][]>([])
  const [navigationGroups, setNavigationGroups] = useState<NavigationGroup[]>([])
  const [selectedNavigationGroupId, setSelectedNavigationGroupId] = useState('')
  const [navigationBusy, setNavigationBusy] = useState(false)
  const [qualityJobId, setQualityJobId] = useState<string>()
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const dragRef = useRef<{ x: number; y: number; originX: number; originY: number } | null>(null)
  const transformRef = useRef<ViewTransform>({ scale: 1, x: 0, y: 0 })
  const transformFrameRef = useRef<number | null>(null)
  const filmstripRef = useRef<HTMLDivElement>(null)
  const assetsRef = useRef<CullingAsset[]>([])
  const nextRowIdRef = useRef<number | null>(null)
  const loadingMoreRef = useRef(false)
  const queryKeyRef = useRef('')
  const currentPhotoIdRef = useRef<string>()
  const lastDataKeyRef = useRef('')
  const positionRestoreLockRef = useRef(false)

  const applyTransform = useCallback((next: ViewTransform) => {
    transformRef.current = next
    if (transformFrameRef.current !== null) return
    transformFrameRef.current = requestAnimationFrame(() => {
      transformFrameRef.current = null
      setTransform(transformRef.current)
    })
  }, [])

  // Resets must not go through the deferred rAF path: a pending frame would
  // read the stale ref value on the next frame (before paint) and overwrite
  // the freshly committed reset — e.g. zooming then arrow-keying to the next
  // photo within ~16ms would keep the old scale. Cancel any pending frame and
  // write ref + state synchronously so the reset is never swallowed.
  const resetTransform = useCallback(() => {
    if (transformFrameRef.current !== null) {
      cancelAnimationFrame(transformFrameRef.current)
      transformFrameRef.current = null
    }
    transformRef.current = { scale: 1, x: 0, y: 0 }
    setTransform({ scale: 1, x: 0, y: 0 })
  }, [])

  const assetQueryKey = useMemo(
    () => ['culling', 'assets', sessionId, scope, filters] as const,
    [filters, scope, sessionId],
  )
  const { data, isLoading, refetch } = useQuery({
    queryKey: assetQueryKey,
    queryFn: () => cullingApi.listPage(sessionId!, scope, filters, undefined, undefined, 500),
    enabled: Boolean(sessionId),
  })
  const [nextRowId, setNextRowId] = useState<number | null>(null)
  const [total, setTotal] = useState<number | undefined>(undefined)
  const { data: summary } = useQuery({
    queryKey: ['culling', 'summary', sessionId],
    queryFn: () => cullingApi.getSummary(sessionId!),
    enabled: Boolean(sessionId),
  })
  const { data: initialSync } = useQuery({
    queryKey: ['culling', 'sync', sessionId],
    queryFn: () => cullingApi.syncStatus(sessionId!),
    enabled: Boolean(sessionId),
  })
  const { data: persistedHistory } = useQuery<CullingHistoryOperation[]>({
    queryKey: ['culling', 'history', sessionId],
    queryFn: () => cullingApi.history(sessionId!, 100),
    enabled: Boolean(sessionId),
  })
  const { data: runningJobs = [] } = useQuery({
    queryKey: ['jobs', 'culling-quality', qualityJobId],
    queryFn: () => jobsApi.list(),
    enabled: Boolean(qualityJobId),
    // Only poll while the watched quality job is queued or running; an idle
    // list doesn't re-fetch every 1s (same conditional polling as the Jobs page).
    refetchInterval: (query) => (
      query.state.data?.some((job) => ['queued', 'running'].includes(job.status))
        ? 1_000
        : false
    ),
  })
  const [syncSummary, setSyncSummary] = useState<MetadataSyncSummary>()
  const { data: conflicts = [], refetch: refetchConflicts } = useQuery({
    queryKey: ['metadata', 'conflicts', sessionId],
    queryFn: () => metadataApi.conflicts(sessionId!),
    enabled: Boolean(sessionId) && (syncSummary?.conflict ?? initialSync?.conflict ?? 0) > 0,
  })

  const analyzeNavigation = useCallback(async (dryRun = false) => {
    if (!sessionId) return
    setNavigationBusy(true)
    try {
      setNavigationGroups(await navigationApi.analyze(sessionId, undefined, undefined, dryRun))
      setMessage(dryRun ? t('culling.navGroupPreview') : t('culling.navGroupSaved'))
    } catch (error) {
      setMessage(error instanceof Error ? translateError(error) : t('culling.navGroupFailed'))
    } finally {
      setNavigationBusy(false)
    }
  }, [sessionId])

  const appendPageAssets = useCallback((incoming: CullingAsset[]) => {
    setAssets(current => {
      if (incoming.length === 0) return current
      const seen = new Set(current.map(asset => asset.photo.id))
      const appended = incoming.filter(asset => !seen.has(asset.photo.id))
      return appended.length > 0 ? [...current, ...appended] : current
    })
  }, [])

  const loadMore = useCallback(async () => {
    if (!sessionId || loadingMoreRef.current) return
    const next = nextRowIdRef.current
    if (next == null) return
    const keyAtStart = queryKeyRef.current
    loadingMoreRef.current = true
    try {
      const page = await cullingApi.listPage(sessionId, scope, filters, undefined, next, 500)
      // Scope/filters may have changed while the page was in flight; the new
      // query refetch will reset the list, so discard a stale page.
      if (queryKeyRef.current !== keyAtStart) return
      appendPageAssets(page.assets)
      setNextRowId(page.nextRowId)
      setTotal(page.total)
    } catch {
      setMessage(t('culling.loadMoreFailed'))
    } finally {
      loadingMoreRef.current = false
    }
  }, [appendPageAssets, filters, scope, sessionId])

  /** Appends pages starting at `baseNextRowId` (deduped against `baseIds`,
   * mirroring `appendPageAssets`) until `photoId` is found. Returns the
   * cumulative index of `photoId` — rowid order guarantees earlier photos
   * surface first — or -1 when exhausted or when the 20-page safety cap is
   * hit. The index is computed locally because `assetsRef` only catches up
   * after the next render. */
  const loadUntilPhoto = useCallback(async (
    photoId: string,
    baseCount: number,
    baseNextRowId: number | null,
    baseIds: Set<string>,
  ): Promise<number> => {
    if (!sessionId) return -1
    const keyAtStart = queryKeyRef.current
    let next = baseNextRowId
    let index = baseCount
    for (let pageCount = 0; pageCount < 20 && next != null; pageCount++) {
      const page = await cullingApi.listPage(sessionId, scope, filters, undefined, next, 500)
      if (queryKeyRef.current !== keyAtStart) return -1
      appendPageAssets(page.assets)
      setNextRowId(page.nextRowId)
      next = page.nextRowId
      for (const asset of page.assets) {
        if (baseIds.has(asset.photo.id)) continue
        baseIds.add(asset.photo.id)
        if (asset.photo.id === photoId) return index
        index++
      }
    }
    return -1
  }, [appendPageAssets, filters, scope, sessionId])

  /** Loads pages until `photoId` is present and returns its cumulative index
   * (or -1 when exhausted or when the 20-page safety cap is hit). */
  const ensureLoadedUntilPhoto = useCallback(async (photoId: string): Promise<number> => {
    if (!sessionId) return -1
    const already = assetsRef.current.findIndex(asset => asset.photo.id === photoId)
    if (already >= 0) return already
    return loadUntilPhoto(
      photoId,
      assetsRef.current.length,
      nextRowIdRef.current,
      new Set(assetsRef.current.map(asset => asset.photo.id)),
    )
  }, [loadUntilPhoto])

  /** Fetches every member of a similarity group via the paginated
   * `similarity_group` scope (groups are small; capped at 20 pages). */
  const fetchGroupAssets = useCallback(async (groupId: string): Promise<CullingAsset[]> => {
    if (!sessionId) return []
    const collected: CullingAsset[] = []
    let afterRowId: number | undefined
    for (let pageCount = 0; pageCount < 20; pageCount++) {
      const page = await cullingApi.listPage(sessionId, 'similarity_group', {}, groupId, afterRowId, 500)
      const seen = new Set(collected.map(asset => asset.photo.id))
      for (const asset of page.assets) {
        if (!seen.has(asset.photo.id)) collected.push(asset)
      }
      if (page.nextRowId == null) break
      afterRowId = page.nextRowId
    }
    return collected
  }, [sessionId])

  const jumpToNavigationGroup = useCallback(async (group: NavigationGroup) => {
    const first = group.photoIds[0]
    const index = await ensureLoadedUntilPhoto(first)
    if (index < 0) {
      setMessage(t('culling.targetNotLoaded'))
      return
    }
    setCurrentIndex(index)
    resetTransform()
  }, [ensureLoadedUntilPhoto, resetTransform])

  useEffect(() => {
    currentPhotoIdRef.current = assets[currentIndex]?.photo.id
  }, [assets, currentIndex])
  useEffect(() => {
    if (!data) return
    const key = JSON.stringify(assetQueryKey)
    const keyChanged = lastDataKeyRef.current !== key
    lastDataKeyRef.current = key
    const restorePosition = !keyChanged && !positionRestoreLockRef.current
    positionRestoreLockRef.current = false
    const previousId = currentPhotoIdRef.current
    setAssets(data.assets)
    setNextRowId(data.nextRowId)
    setTotal(data.total)
    if (
      restorePosition &&
      previousId &&
      !data.assets.some(asset => asset.photo.id === previousId)
    ) {
      // A refetch replaces the list with the fresh first page, dropping any
      // deeper scroll position; resume loading from that page until the
      // previously viewed photo surfaces again so the window does not reset.
      const freshIds = new Set(data.assets.map(asset => asset.photo.id))
      void loadUntilPhoto(previousId, data.assets.length, data.nextRowId, freshIds)
        .then(index => {
          if (index >= 0) {
            setCurrentIndex(index)
            resetTransform()
          }
        })
    }
  }, [assetQueryKey, data, loadUntilPhoto, resetTransform])
  useEffect(() => {
    assetsRef.current = assets
  }, [assets])
  useEffect(() => {
    nextRowIdRef.current = nextRowId
  }, [nextRowId])
  useEffect(() => {
    if (transformRef.current !== transform) {
      transformRef.current = transform
    }
  }, [transform])
  useEffect(() => () => {
    if (transformFrameRef.current !== null) {
      cancelAnimationFrame(transformFrameRef.current)
    }
  }, [])
  useEffect(() => {
    queryKeyRef.current = JSON.stringify(assetQueryKey)
  }, [assetQueryKey])
  useEffect(() => {
    if (assets.length === 0 && nextRowId != null && !loadingMoreRef.current) {
      void loadMore()
    }
  }, [assets.length, loadMore, nextRowId])
  useEffect(() => {
    if (initialSync) setSyncSummary(initialSync)
  }, [initialSync])
  useEffect(() => {
    if (!persistedHistory) return
    const command = (operation: CullingHistoryOperation): HistoryEntry[] =>
      operation.entries.map(entry => ({ ...entry, operationId: operation.id }))
    setUndoStack(
      persistedHistory.filter(operation => !operation.undone).reverse().map(command),
    )
    setRedoStack(
      persistedHistory.filter(operation => operation.undone).map(command),
    )
  }, [persistedHistory])
  useEffect(() => {
    if (!qualityJobId) return
    const job = runningJobs.find(candidate => candidate.id === qualityJobId)
    if (!job || ['queued', 'running', 'cancelling'].includes(job.status)) return
    if (job.status === 'succeeded') {
      setMessage(t('culling.qualityDone'))
      void refetch()
    } else {
      setMessage(translateErrorCode(job.errorMessage) || t('culling.qualityIncomplete'))
    }
    setQualityJobId(undefined)
  }, [qualityJobId, refetch, runningJobs])
  const conflictCountRef = useRef<number>(0)
  conflictCountRef.current = syncSummary?.conflict ?? initialSync?.conflict ?? 0
  const pendingSyncRef = useRef<MetadataSyncSummary | null>(null)
  const syncSummaryFrameRef = useRef<number | null>(null)

  // Applies one sync-status payload. Only the fields that actually render
  // (badge counts + the items-empty state behind syncLabel) are compared
  // before committing, so a burst of equivalent summaries does not re-render
  // the whole 1700-line page.
  const applySyncStatus = useCallback((summary: MetadataSyncSummary) => {
    if (summary.sessionId !== sessionId) return
    const previousConflicts = conflictCountRef.current
    setSyncSummary(current => (
      current &&
      current.conflict === summary.conflict &&
      current.failed === summary.failed &&
      current.written === summary.written &&
      current.synced === summary.synced &&
      current.pending === summary.pending &&
      current.writing === summary.writing &&
      (current.items.length === 0) === (summary.items.length === 0)
    ) ? current : summary)
    setAssets(current => {
      if (summary.items.length === 0) return current
      const statusByXmpPath = new Map(summary.items.map(item => [item.xmpPath, item.status]))
      // Short circuit: none of the loaded assets change status, so keep the
      // current array reference and skip the O(n) copy entirely.
      if (!current.some(asset => statusByXmpPath.has(asset.xmpPath))) return current
      let changed = 0
      const updated = current.map(asset => {
        const status = statusByXmpPath.get(asset.xmpPath)
        if (status !== undefined && status !== asset.syncStatus) {
          changed++
          return { ...asset, syncStatus: status }
        }
        return asset
      })
      return changed > 0 ? updated : current
    })
    // Path summaries are emitted per xmp_path, so one flush can raise the
    // conflict count 1..N across several events; refetch on any change.
    if (summary.conflict > 0 && summary.conflict !== previousConflicts) {
      void refetchConflicts()
    }
  }, [refetchConflicts, sessionId])
  const applySyncStatusRef = useRef(applySyncStatus)
  applySyncStatusRef.current = applySyncStatus
  useEvent('culling:sync-status', (payload) => {
    const next = payload as MetadataSyncSummary
    if (next.sessionId !== sessionId) return
    // Coalesce a flush's event burst into at most one pass per frame (the
    // same rAF pattern as applyTransform): keep the latest payload and apply
    // it once when the frame rolls. Each payload is a complete summary, so
    // dropping the intermediate ones loses no state.
    pendingSyncRef.current = next
    if (syncSummaryFrameRef.current !== null) return
    syncSummaryFrameRef.current = requestAnimationFrame(() => {
      syncSummaryFrameRef.current = null
      const summary = pendingSyncRef.current
      pendingSyncRef.current = null
      if (summary) applySyncStatusRef.current(summary)
    })
  }, Boolean(sessionId))
  useEffect(() => () => {
    if (syncSummaryFrameRef.current !== null) {
      cancelAnimationFrame(syncSummaryFrameRef.current)
    }
  }, [])
  useEffect(() => {
    setCurrentIndex(index => Math.min(index, Math.max(0, assets.length - 1)))
  }, [assets.length])
  useEffect(() => {
    filmstripRef.current
      ?.querySelector<HTMLElement>('[data-current="true"]')
      ?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  }, [currentIndex])
  useEffect(() => {
    setCurrentIndex(0)
    setSelectedIds(new Set())
    setUndoStack([])
    setRedoStack([])
    setNextRowId(null)
    setTotal(undefined)
    loadingMoreRef.current = false
  }, [sessionId])

  const current = assets[currentIndex]
  // Prebuilt per-assets indexes so navigation uses O(1) lookups instead of
  // filtering the whole loaded list (up to 10k assets) on every step; the
  // indexes only rebuild when the assets array itself changes.
  const assetsIndex = useMemo(() => {
    const byId = new Map<string, CullingAsset>()
    const byGroup = new Map<string, CullingAsset[]>()
    for (const asset of assets) {
      byId.set(asset.photo.id, asset)
      if (asset.similarityGroupId) {
        const group = byGroup.get(asset.similarityGroupId)
        if (group) group.push(asset)
        else byGroup.set(asset.similarityGroupId, [asset])
      }
    }
    return { byId, byGroup }
  }, [assets])
  const assetById = assetsIndex.byId
  const currentGroupAssets = useMemo(() => {
    if (!current?.similarityGroupId) return current ? [current] : []
    // Group members keep the global asset order, same semantics as the
    // previous assets.filter pass.
    return assetsIndex.byGroup.get(current.similarityGroupId) ?? []
  }, [assetsIndex, current])
  const comparisonAssets = useMemo(() => {
    if (!current) return []
    if (compareCount === 1) return [current]
    const pool = current.similarityGroupId
      ? assetsIndex.byGroup.get(current.similarityGroupId) ?? []
      : assets
    // Matches [current, ...pool minus current].slice(0, compareCount) without
    // allocating the full filtered list: take the first compareCount - 1
    // other members after the current photo.
    const others: CullingAsset[] = []
    for (const asset of pool) {
      if (asset.photo.id === current.photo.id) continue
      others.push(asset)
      if (others.length >= compareCount - 1) break
    }
    return [current, ...others]
  }, [assets, assetsIndex, compareCount, current])
  const stripStart = Math.max(0, currentIndex - 50)
  const stripAssets = assets.slice(stripStart, stripStart + 101)
  const effectiveTargetIds = selectedIds.size > 0
    ? [...selectedIds]
    : current ? [current.photo.id] : []

  const currentPhotoId = current?.photo.id
  useEffect(() => {
    if (!currentPhotoId) return
    const preload = assetsRef.current
      .slice(currentIndex, currentIndex + 8)
      .map(asset => asset.photo.filepath)
    void imageApi.preloadPreviews(preload, 2560).catch(() => undefined)
  }, [currentPhotoId, currentIndex])

  const applyResult = useCallback((result: CullingUpdateResult) => {
    const states = new Map(result.states.map(state => [state.photoId, state]))
    setAssets(currentAssets => currentAssets.map(asset => {
      const nextState = states.get(asset.photo.id)
      if (nextState) {
        return {
          ...asset,
          state: nextState,
          syncStatus: asset.xmpPath === result.xmpPath
            ? result.syncStatus
            : asset.syncStatus,
        }
      }
      return asset.xmpPath === result.xmpPath
        ? { ...asset, syncStatus: result.syncStatus }
        : asset
    }))
  }, [])

  const refreshFiltered = useCallback(async (preferredPhotoId?: string) => {
    if (scope !== 'filtered') return
    const refreshed = await refetch()
    const nextAssets = refreshed.data?.assets ?? []
    setAssets(nextAssets)
    setNextRowId(refreshed.data?.nextRowId ?? null)
    setTotal(refreshed.data?.total)
    setCurrentIndex(currentValue => {
      if (preferredPhotoId) {
        const preferredIndex = nextAssets.findIndex(
          asset => asset.photo.id === preferredPhotoId,
        )
        if (preferredIndex >= 0) return preferredIndex
      }
      return Math.min(currentValue, Math.max(0, nextAssets.length - 1))
    })
  }, [refetch, scope])

  const advance = useCallback(() => {
    setCurrentIndex(index => {
      if (index >= assets.length - 1 && nextRowIdRef.current != null) {
        // End of the loaded window but more pages exist — kick off the next
        // page in the background so consecutive advances keep working.
        void loadMore()
        return index
      }
      return Math.min(index + 1, Math.max(0, assets.length - 1))
    })
    resetTransform()
  }, [assets.length, loadMore, resetTransform])

  const commitOne = useCallback(async (
    photoId: string,
    patch: CullingUpdatePatch,
    recordHistory = true,
    shouldAdvance = false,
  ) => {
    if (!sessionId) return
    const beforeAsset = assetById.get(photoId)
    if (!beforeAsset) return
    const stableNextId = assets[currentIndex + 1]?.photo.id
    setBusy(true)
    setMessage('')
    try {
      const result = await cullingApi.update(
        sessionId,
        photoId,
        beforeAsset.state.revision,
        patch,
      )
      applyResult(result)
      if (result.syncStatus !== 'clean') {
        void cullingApi.syncStatus(sessionId).then(setSyncSummary)
      }
      const targetState = result.states.find(state => state.photoId === photoId)
      if (recordHistory) {
        if (targetState && result.historyOperationId !== undefined) {
          setUndoStack(stack => [...stack.slice(-99), [{
            operationId: result.historyOperationId!,
            photoId,
            before: {
              pickState: beforeAsset.state.pickState,
              rating: beforeAsset.state.rating,
              colorLabel: beforeAsset.state.colorLabel,
            },
            after: {
              pickState: targetState.pickState,
              rating: targetState.rating,
              colorLabel: targetState.colorLabel,
            },
            expectedRevision: targetState.revision,
            fields: Object.keys(patch) as Array<keyof CullingUpdatePatch>,
          }]])
        }
        setRedoStack([])
      }
      void queryClient.invalidateQueries({ queryKey: ['culling', 'summary', sessionId] })
      if (scope === 'filtered') {
        await refreshFiltered(shouldAdvance && autoAdvance ? stableNextId : photoId)
      } else if (shouldAdvance && autoAdvance) {
        advance()
      }
    } catch (error) {
      setMessage(error instanceof Error ? translateError(error) : t('culling.updateFailed'))
      await refetch()
    } finally {
      setBusy(false)
    }
  }, [
    advance,
    applyResult,
    assets,
    assetById,
    autoAdvance,
    currentIndex,
    queryClient,
    refetch,
    refreshFiltered,
    scope,
    sessionId,
  ])

  const commitTargets = useCallback(async (
    patch: CullingUpdatePatch,
    shouldAdvance = true,
  ) => {
    if (!sessionId || effectiveTargetIds.length === 0) return
    if (effectiveTargetIds.length === 1) {
      await commitOne(effectiveTargetIds[0], patch, true, shouldAdvance)
      return
    }
    setBusy(true)
    const stableNextId = assets[currentIndex + 1]?.photo.id
    try {
      const results = await cullingApi.batchUpdate(sessionId, effectiveTargetIds, patch)
      results.forEach(applyResult)
      if (results.some(result => result.syncStatus !== 'clean')) {
        void cullingApi.syncStatus(sessionId).then(setSyncSummary)
      }
      const operationTargetIds = patch.pickState === undefined
        ? [...new Map(effectiveTargetIds.flatMap(photoId => {
          const asset = assetById.get(photoId)
          return asset ? [[asset.xmpPath, photoId] as const] : []
        })).values()]
        : effectiveTargetIds
      const operationId = results.find(result => result.historyOperationId !== undefined)
        ?.historyOperationId
      const historyCommand = results.flatMap((result, index) => {
        const targetId = operationTargetIds[index]
        const beforeAsset = targetId ? assetById.get(targetId) : undefined
        const targetState = result.states.find(state => state.photoId === targetId)
        if (!beforeAsset || !targetState || operationId === undefined) return []
        return [{
          operationId,
          photoId: targetId,
          before: {
            pickState: beforeAsset.state.pickState,
            rating: beforeAsset.state.rating,
            colorLabel: beforeAsset.state.colorLabel,
          },
          after: {
            pickState: targetState.pickState,
            rating: targetState.rating,
            colorLabel: targetState.colorLabel,
          },
          expectedRevision: targetState.revision,
          fields: Object.keys(patch) as Array<keyof CullingUpdatePatch>,
        }]
      })
      if (historyCommand.length > 0) {
        setUndoStack(stack => [...stack.slice(-99), historyCommand])
        setRedoStack([])
      }
      setSelectedIds(new Set())
      void queryClient.invalidateQueries({ queryKey: ['culling', 'summary', sessionId] })
      if (scope === 'filtered') {
        await refreshFiltered(shouldAdvance && autoAdvance ? stableNextId : undefined)
      } else if (shouldAdvance && autoAdvance) {
        advance()
      }
    } catch (error) {
      setMessage(error instanceof Error ? translateError(error) : t('culling.batchUpdateFailed'))
      await refetch()
    } finally {
      setBusy(false)
    }
  }, [
    advance,
    applyResult,
    assets,
    assetById,
    autoAdvance,
    effectiveTargetIds,
    commitOne,
    currentIndex,
    queryClient,
    refetch,
    refreshFiltered,
    sessionId,
    scope,
  ])

  const undo = useCallback(async () => {
    const command = undoStack[undoStack.length - 1]
    if (!command || !sessionId) return
    setBusy(true)
    setUndoStack(stack => stack.slice(0, -1))
    try {
      const results = await cullingApi.applyHistory(
        sessionId,
        command.map(entry => ({
          photoId: entry.photoId,
          expectedRevision: entry.expectedRevision,
          patch: statePatch(entry.before, entry.fields),
        })),
        command[0].operationId,
        'undo',
      )
      results.forEach(applyResult)
      const states = new Map(results.flatMap(result => result.states).map(state => [state.photoId, state]))
      const redoCommand = command.map(entry => ({
        ...entry,
        expectedRevision: states.get(entry.photoId)?.revision ?? entry.expectedRevision + 1,
      }))
      if (results.some(result => result.syncStatus !== 'clean')) {
        void cullingApi.syncStatus(sessionId).then(setSyncSummary)
      }
      setRedoStack(stack => [...stack, redoCommand])
      await refreshFiltered(command[0]?.photoId)
      // The persisted `undone` flags changed server-side; drop the stale cache
      // so a remount re-seeds undo/redo stacks from fresh history.
      void queryClient.invalidateQueries({ queryKey: ['culling', 'history', sessionId] })
    } catch (error) {
      setUndoStack([])
      setRedoStack([])
      setMessage(error instanceof Error
        ? t('culling.undoResetWithError', { message: translateError(error) })
        : t('culling.undoReset'))
      await refetch()
    } finally {
      setBusy(false)
    }
  }, [applyResult, queryClient, refetch, refreshFiltered, sessionId, undoStack])

  const redo = useCallback(async () => {
    const command = redoStack[redoStack.length - 1]
    if (!command || !sessionId) return
    setBusy(true)
    setRedoStack(stack => stack.slice(0, -1))
    try {
      const results = await cullingApi.applyHistory(
        sessionId,
        command.map(entry => ({
          photoId: entry.photoId,
          expectedRevision: entry.expectedRevision,
          patch: statePatch(entry.after, entry.fields),
        })),
        command[0].operationId,
        'redo',
      )
      results.forEach(applyResult)
      const states = new Map(results.flatMap(result => result.states).map(state => [state.photoId, state]))
      const undoCommand = command.map(entry => ({
        ...entry,
        expectedRevision: states.get(entry.photoId)?.revision ?? entry.expectedRevision + 1,
      }))
      if (results.some(result => result.syncStatus !== 'clean')) {
        void cullingApi.syncStatus(sessionId).then(setSyncSummary)
      }
      setUndoStack(stack => [...stack, undoCommand])
      await refreshFiltered(command[0]?.photoId)
      // Keep the query cache consistent with the persisted `undone` flags.
      void queryClient.invalidateQueries({ queryKey: ['culling', 'history', sessionId] })
    } catch (error) {
      setUndoStack([])
      setRedoStack([])
      setMessage(error instanceof Error
        ? t('culling.redoResetWithError', { message: translateError(error) })
        : t('culling.redoReset'))
      await refetch()
    } finally {
      setBusy(false)
    }
  }, [applyResult, queryClient, redoStack, refetch, refreshFiltered, sessionId])

  const keepInGroupRejectRest = useCallback(async (keepPhotoIds: string[]) => {
    if (
      !sessionId ||
      !current?.similarityGroupId ||
      keepPhotoIds.length < 1
    ) return
    setBusy(true)
    setMessage('')
    try {
      // Fetch the whole group through the paginated similarity_group scope
      // (server pushes the group filter down to SQL) instead of the full
      // session list.
      const allAssets = await fetchGroupAssets(current.similarityGroupId)
      const fullGroup = allAssets.filter(
        asset => asset.similarityGroupId === current.similarityGroupId,
      )
      const groupIds = new Set(fullGroup.map(asset => asset.photo.id))
      if (
        fullGroup.length < 2 ||
        keepPhotoIds.some(photoId => !groupIds.has(photoId))
      ) {
        throw new Error(t('culling.groupChanged'))
      }

      const results = await cullingApi.decideGroup(
        sessionId,
        current.similarityGroupId,
        keepPhotoIds,
      )
      results.forEach(applyResult)
      const operationId = results.find(result => result.historyOperationId !== undefined)
        ?.historyOperationId

      const historyCommand = fullGroup.flatMap((asset) => {
        const targetState = results
          .flatMap(result => result.states)
          .find(state => state.photoId === asset.photo.id)
        if (
          !targetState ||
          targetState.pickState === asset.state.pickState ||
          operationId === undefined
        ) return []
        return [{
          operationId,
          photoId: asset.photo.id,
          before: {
            pickState: asset.state.pickState,
            rating: asset.state.rating,
            colorLabel: asset.state.colorLabel,
          },
          after: {
            pickState: targetState.pickState,
            rating: targetState.rating,
            colorLabel: targetState.colorLabel,
          },
          expectedRevision: targetState.revision,
          fields: ['pickState'] as Array<keyof CullingUpdatePatch>,
        }]
      })
      if (historyCommand.length > 0) {
        setUndoStack(stack => [...stack.slice(-99), historyCommand])
        setRedoStack([])
      }
      if (results.some(result => result.syncStatus !== 'clean')) {
        void cullingApi.syncStatus(sessionId).then(setSyncSummary)
      }
      setSelectedIds(new Set())
      void queryClient.invalidateQueries({ queryKey: ['culling', 'summary', sessionId] })
      // This flow positions itself after the refetch; the data effect must
      // not restore the previous scroll position on top of the group advance.
      positionRestoreLockRef.current = true
      await refetch()
      if (autoAdvance) {
        const nextIndex = assets.findIndex(
          (asset, index) =>
            index > currentIndex &&
            asset.similarityGroupId !== current.similarityGroupId,
        )
        if (nextIndex >= 0) {
          setCurrentIndex(nextIndex)
          resetTransform()
        }
      }
    } catch (error) {
      setMessage(error instanceof Error ? translateError(error) : t('culling.groupOpFailed'))
      await refetch()
    } finally {
      setBusy(false)
    }
  }, [
    applyResult,
    assets,
    autoAdvance,
    current,
    currentIndex,
    fetchGroupAssets,
    queryClient,
    refetch,
    resetTransform,
    sessionId,
  ])

  const flush = useCallback(async () => {
    if (!sessionId) return
    setBusy(true)
    try {
      setSyncSummary(await cullingApi.flush(sessionId))
    } catch (error) {
      setMessage(error instanceof Error ? translateError(error) : t('culling.xmpWriteFailed'))
    } finally {
      setBusy(false)
    }
  }, [sessionId])

  // The handler is held in a ref (the same "latest callback" pattern as the
  // useEvent hook) so the window listener mounts exactly once: reassigning
  // the ref each render keeps hot callbacks — commitTargets, undo, redo,
  // busy — fresh without remove/add on every keydown-relevant re-render.
  const keydownHandlerRef = useRef<(event: KeyboardEvent) => void>(() => {})
  keydownHandlerRef.current = (event) => {
    const target = event.target
    if (
      target instanceof HTMLInputElement ||
      target instanceof HTMLTextAreaElement ||
      target instanceof HTMLSelectElement
    ) return
    const mod = event.metaKey || event.ctrlKey
    if (mod && event.key.toLowerCase() === 'z') {
      event.preventDefault()
      void (event.shiftKey ? redo() : undo())
      return
    }
    if (busy) return
    if (/^[0-5]$/.test(event.key)) {
      event.preventDefault()
      void commitTargets({ rating: Number(event.key) })
    } else if (event.key.toLowerCase() === 'p' || event.key === ' ') {
      event.preventDefault()
      void commitTargets({ pickState: 'picked' })
    } else if (event.key.toLowerCase() === 'x') {
      event.preventDefault()
      void commitTargets({ pickState: 'rejected' })
    } else if (event.key.toLowerCase() === 'u') {
      event.preventDefault()
      void commitTargets({ pickState: 'unreviewed' }, false)
    } else if (event.key === 'ArrowLeft') {
      event.preventDefault()
      setCurrentIndex(index => Math.max(0, index - 1))
      resetTransform()
    } else if (event.key === 'ArrowRight') {
      event.preventDefault()
      advance()
    }
  }
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => keydownHandlerRef.current(event)
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  if (!sessionId) {
    return <div className={styles.emptyState}>{t('culling.noWorkspace')}</div>
  }
  if (isLoading) {
    return <div className={styles.emptyState}>{t('culling.loading')}</div>
  }
  if (!assets.length) {
    return (
      <div className={styles.page}>
        <div className={styles.toolbar}>
          <div className={styles.toolbarSection}>
            <ScopeControls scope={scope} setScope={setScope} />
          </div>
          <div className={styles.filterSection}>
            <FilterControls filters={filters} setFilters={setFilters} />
          </div>
        </div>
        <div className={styles.emptyState}>
          {t('culling.empty')}
        </div>
      </div>
    )
  }

  return (
    <div className={styles.page}>
      <div className={styles.toolbar}>
        <div className={styles.toolbarSection}>
          <ScopeControls scope={scope} setScope={setScope} />
        </div>
        <div className={styles.filterSection}>
          <FilterControls filters={filters} setFilters={setFilters} />
        </div>
        <div className={styles.viewSection}>
          <button onClick={() => void analyzeNavigation()} disabled={navigationBusy}>
            {navigationBusy ? t('culling.navAnalyzing') : t('culling.navSave')}
          </button>
          <button onClick={() => void analyzeNavigation(true)} disabled={navigationBusy}>
            {t('culling.navPreview')}
          </button>
          <button
            disabled={Boolean(qualityJobId)}
            onClick={() => {
              void qualityApi.analyze(sessionId).then(job => {
                setQualityJobId(job.id)
                setMessage(t('culling.qualityQueued'))
              }).catch(error => {
                setMessage(error instanceof Error ? translateError(error) : t('culling.qualityStartFailed'))
              })
            }}
          >
            {qualityJobId ? t('culling.qualityRunning') : t('culling.qualityAnalyze')}
          </button>
          {navigationGroups.length > 0 && (
            <select className={styles.select} defaultValue="" onChange={event => {
              setSelectedNavigationGroupId(event.target.value)
              const group = navigationGroups.find(item => item.id === event.target.value)
              if (group) void jumpToNavigationGroup(group)
            }}>
              <option value="">{t('culling.navGroup', { count: navigationGroups.length })}</option>
              {navigationGroups.map(group => (
                <option key={group.id} value={group.id}>
                  {t('culling.navGroupItem', { type: group.type === 'burst' ? 'Burst' : 'Scene', count: group.photoIds.length })}
                  {group.leadPhotoId ? t('culling.navGroupLead', { index: group.photoIds.indexOf(group.leadPhotoId) + 1 }) : ''}
                </option>
              ))}
            </select>
          )}
          {selectedNavigationGroupId && (
            <>
              <button
                title={navExplanation(navigationGroups.find(group => group.id === selectedNavigationGroupId)?.explanation)}
                onClick={() => {
                  const group = navigationGroups.find(item => item.id === selectedNavigationGroupId)
                  if (!group || !current || group.photoIds.indexOf(current.photo.id) <= 0) {
                    setMessage(t('culling.navSplitHint'))
                    return
                  }
                  void navigationApi.split(sessionId, group.id, current.photo.id)
                    .then(setNavigationGroups)
                    .catch(error => setMessage(error instanceof Error ? translateError(error) : t('culling.navSplitFailed')))
                }}
              >
                {t('culling.navSplit')}
              </button>
              <button
                onClick={() => {
                  const index = navigationGroups.findIndex(group => group.id === selectedNavigationGroupId)
                  const selected = navigationGroups[index]
                  const previous = navigationGroups.slice(0, index).reverse()
                    .find(group => group.type === selected?.type)
                  if (!selected || !previous) {
                    setMessage(t('culling.navMergeHint'))
                    return
                  }
                  void navigationApi.merge(sessionId, [previous.id, selected.id])
                    .then(setNavigationGroups)
                    .catch(error => setMessage(error instanceof Error ? translateError(error) : t('culling.navMergeFailed')))
                }}
              >
                {t('culling.navMerge')}
              </button>
            </>
          )}
          <label className={styles.toggle}>
            <input
              type="checkbox"
              checked={autoAdvance}
              onChange={event => setAutoAdvance(event.target.checked)}
            />
            {t('culling.autoAdvance')}
          </label>
          <div className={styles.segmented}>
            {([1, 2, 4] as const).map(count => (
              <button
                key={count}
                className={compareCount === count ? styles.active : ''}
                onClick={() => {
                  setCompareCount(count)
                  resetTransform()
                }}
              >
                {count === 1 ? t('culling.single') : t('culling.multi', { count })}
              </button>
            ))}
          </div>
          <label className={styles.toggle}>
            <input
              type="checkbox"
              checked={faceAlign}
              onChange={event => {
                setFaceAlign(event.target.checked)
                resetTransform()
              }}
            />
            {t('culling.faceAlign')}
          </label>
          <div className={styles.historyActions}>
            <button
              className={styles.iconButton}
              onClick={() => void undo()}
              disabled={!undoStack.length || busy}
              title={t('culling.undo')}
              aria-label={t('culling.undoLabel')}
            >
              ↶
            </button>
            <button
              className={styles.iconButton}
              onClick={() => void redo()}
              disabled={!redoStack.length || busy}
              title={t('culling.redo')}
              aria-label={t('culling.redoLabel')}
            >
              ↷
            </button>
          </div>
        </div>
      </div>

      <div
        className={`${styles.viewer} ${compareCount > 1 ? styles.comparing : ''}`}
        onWheel={event => {
          event.preventDefault()
          const value = transformRef.current
          applyTransform({
            ...value,
            scale: Math.max(1, Math.min(8, value.scale * (event.deltaY < 0 ? 1.15 : 0.87))),
          })
        }}
        onPointerDown={event => {
          event.currentTarget.setPointerCapture(event.pointerId)
          const value = transformRef.current
          dragRef.current = {
            x: event.clientX,
            y: event.clientY,
            originX: value.x,
            originY: value.y,
          }
        }}
        onPointerMove={event => {
          const drag = dragRef.current
          if (!drag) return
          const value = transformRef.current
          applyTransform({
            ...value,
            x: drag.originX + event.clientX - drag.x,
            y: drag.originY + event.clientY - drag.y,
          })
        }}
        onPointerUp={() => { dragRef.current = null }}
        onDoubleClick={() => resetTransform()}
      >
        {comparisonAssets.map(asset => (
          <CullingImage
            key={asset.photo.id}
            asset={asset}
            transform={transform}
            faceAlign={faceAlign}
          />
        ))}
        <button
          className={`${styles.navButton} ${styles.previous}`}
          onClick={() => {
            setCurrentIndex(index => Math.max(0, index - 1))
            resetTransform()
          }}
          disabled={currentIndex === 0}
          aria-label={t('culling.prevPhoto')}
        >
          ‹
        </button>
        <button
          className={`${styles.navButton} ${styles.next}`}
          onClick={advance}
          disabled={currentIndex === assets.length - 1 && nextRowId === null}
          aria-label={t('culling.nextPhoto')}
        >
          ›
        </button>
        <div className={styles.zoomHint}>
          {Math.round((faceAlign ? Math.max(2, transform.scale) : transform.scale) * 100)}%
          {t('culling.zoomHint')}
        </div>
      </div>

      {sessionId && conflicts.length > 0 && (
        <ConflictPanel
          sessionId={sessionId}
          conflicts={conflicts}
          onResolved={(next) => {
            setSyncSummary(next)
            void refetchConflicts()
          }}
        />
      )}

      <div className={styles.infoBar}>
        <span className={styles.positionCount}>{currentIndex + 1} / {total ?? assets.length}</span>
        <span className={styles.keptStat}>{t('culling.keptCount', { count: summary?.kept ?? 0 })}</span>
        <span className={styles.rejectedStat}>{t('culling.rejectedCount', { count: summary?.rejected ?? 0 })}</span>
        <span>{t('culling.pendingCount', { count: summary?.pending ?? assets.length })}</span>
        {current?.linkedVariantCount && current.linkedVariantCount > 1 && (
          <span className={styles.linkedNotice}>
            {t('culling.linkedNotice', { count: current.linkedVariantCount })}
          </span>
        )}
        <span className={`${styles.syncState} ${
          (syncSummary?.failed ?? 0) + (syncSummary?.conflict ?? 0) > 0
            ? styles.syncError
            : ''
        }`}>
          {syncLabel(syncSummary, t)}
        </span>
        <button onClick={() => void flush()} disabled={busy}>{t('culling.flush')}</button>
        {(syncSummary?.written ?? 0) > 0 && (
          <button
            disabled={busy}
            onClick={() => {
              setBusy(true)
              void window.gather.reloadMetadata()
                .then(() => setMessage(t('culling.reloadDone')))
                .catch(error => addToast('error', error instanceof Error ? translateError(error) : t('culling.reloadFailed')))
                .finally(() => setBusy(false))
            }}
          >
            {t('culling.reloadBtn')}
          </button>
        )}
        {(syncSummary?.written ?? 0) > 0 && (
          <span className={styles.syncHint}>{t('culling.syncHint')}</span>
        )}
        {(syncSummary?.failed ?? 0) > 0 && (
          <button
            onClick={() => {
              if (!sessionId) return
              setBusy(true)
              void cullingApi.retrySync(sessionId)
                .then(setSyncSummary)
                .catch(error => setMessage(error instanceof Error ? translateError(error) : t('culling.retryFailedError')))
                .finally(() => setBusy(false))
            }}
          >
            {t('culling.retryFailed')}
          </button>
        )}
        {(syncSummary?.written ?? 0) > 0 && (
          <button
            onClick={() => {
              if (!sessionId) return
              setBusy(true)
              void cullingApi.confirmSync(sessionId)
                .then(() => cullingApi.syncStatus(sessionId))
                .then(setSyncSummary)
                .catch(error => setMessage(error instanceof Error ? translateError(error) : t('culling.confirmFailed')))
                .finally(() => setBusy(false))
            }}
          >
            {t('culling.confirmLoaded')}
          </button>
        )}
        {(syncSummary?.synced ?? 0) > 0 && (
          <>
            <button
              onClick={() => {
                if (!sessionId) return
                setBusy(true)
                void cullingApi.finalizeSync(sessionId)
                  .then(summary => {
                    setMessage(t('culling.finalizeDone'))
                    setSyncSummary(summary)
                  })
                  .catch(error => setMessage(error instanceof Error ? translateError(error) : t('culling.finalizeFailed')))
                  .finally(() => setBusy(false))
              }}
            >
              {t('culling.finalizeBtn')}
            </button>
            <button
              onClick={() => {
                if (!sessionId) return
                setBusy(true)
                void cullingApi.cleanup(sessionId)
                  .then(result => {
                    setMessage(result.errors.length > 0
                      ? t('culling.cleanupError', { count: result.errors.length, detail: result.errors[0] })
                      : t('culling.cleanupDone', { count: result.deletedCount }))
                    return cullingApi.syncStatus(sessionId)
                  })
                  .then(setSyncSummary)
                  .catch(error => setMessage(error instanceof Error ? translateError(error) : t('culling.cleanupFailed')))
                  .finally(() => setBusy(false))
              }}
            >
              {t('culling.restoreXmp')}
            </button>
          </>
        )}
      </div>

      <div
        className={styles.filmstrip}
        ref={filmstripRef}
        onScroll={event => {
          const element = event.currentTarget
          if (element.scrollHeight - element.scrollTop - element.clientHeight < 400) {
            void loadMore()
          }
        }}
      >
        <div className={styles.stripHeader}>
          <span>{t('culling.filmstrip')}</span>
          <span>{assets.length}{total != null && total > assets.length ? ` / ${total}` : ''}</span>
        </div>
        <div className={styles.stripSpacer} style={{ width: stripStart * 86 }} />
        {stripAssets.map((asset, offset) => {
          const index = stripStart + offset
          return (
            <button
              key={asset.photo.id}
              className={`${styles.thumbnail} ${
                index === currentIndex ? styles.currentThumbnail : ''
              } ${selectedIds.has(asset.photo.id) ? styles.selectedThumbnail : ''}`}
              data-current={index === currentIndex}
              onClick={event => {
                if (event.metaKey || event.ctrlKey || event.shiftKey) {
                  setSelectedIds(previous => {
                    const next = new Set(previous)
                    if (next.has(asset.photo.id)) {
                      next.delete(asset.photo.id)
                    } else {
                      next.add(asset.photo.id)
                    }
                    return next
                  })
                } else {
                  setCurrentIndex(index)
                  resetTransform()
                }
              }}
              title={asset.photo.filename}
            >
              <FilmThumb filepath={asset.photo.filepath} filename={asset.photo.filename} />
              <span
                className={styles.colorLine}
                style={{
                  background: COLOR_LABELS.find(
                    label => label.value === asset.state.colorLabel,
                  )?.color,
                }}
              />
              <span className={styles.thumbRating}>
                {asset.state.rating ? `${asset.state.rating}★` : ''}
              </span>
              <span className={`${styles.thumbDecision} ${
                asset.state.pickState === 'picked'
                  ? styles.picked
                  : asset.state.pickState === 'rejected'
                    ? styles.rejected
                    : ''
              }`} />
              <span className={styles.thumbFilename}>{asset.photo.filename}</span>
            </button>
          )
        })}
        <div
          className={styles.stripSpacer}
          style={{ width: Math.max(0, assets.length - stripStart - stripAssets.length) * 86 }}
        />
        {nextRowId != null && (
          <button
            style={{
              flex: '0 0 auto',
              width: '100%',
              height: 36,
              marginTop: 4,
              border: '1px solid var(--cull-border)',
              borderRadius: 4,
              background: 'transparent',
              color: 'var(--cull-text)',
              cursor: 'pointer',
            }}
            onClick={() => void loadMore()}
            disabled={loadingMoreRef.current}
          >
            {loadingMoreRef.current ? t('culling.loadingMore') : t('culling.loadMore')}
          </button>
        )}
      </div>

      <div className={styles.controls}>
        <div className={styles.panelTitle}>{t('culling.tools')}</div>
        <div className={styles.controlGroup}>
          <span className={styles.controlLabel}>
            {selectedIds.size > 0 ? t('culling.batchCount', { count: selectedIds.size }) : t('culling.currentPhoto')}
          </span>
          <div className={styles.decisionBar}>
            <button
              className={`${styles.decisionButton} ${styles.pickButton}`}
              onClick={() => void commitTargets({ pickState: 'picked' })}
              disabled={busy}
              aria-label={t('culling.pickShortcut')}
            >
              <span className={styles.decisionIcon}>✓</span>
              <span>{t('culling.picked')}</span>
              <span className={styles.shortcut}>P</span>
            </button>
            <button
              className={`${styles.decisionButton} ${styles.rejectButton}`}
              onClick={() => void commitTargets({ pickState: 'rejected' })}
              disabled={busy}
              aria-label={t('culling.rejectShortcut')}
            >
              <span className={styles.decisionIcon}>×</span>
              <span>{t('culling.rejected')}</span>
              <span className={styles.shortcut}>X</span>
            </button>
            <button
              className={`${styles.decisionButton} ${styles.clearButton}`}
              onClick={() => void commitTargets({ pickState: 'unreviewed' }, false)}
              disabled={busy}
              aria-label={t('culling.clearShortcut')}
            >
              <span className={styles.decisionIcon}>○</span>
              <span>{t('culling.statusUnreviewed')}</span>
              <span className={styles.shortcut}>U</span>
            </button>
          </div>
        </div>
        <div className={styles.controlGroup}>
          <span className={styles.controlLabel}>{t('culling.rating')}</span>
          {[0, 1, 2, 3, 4, 5].map(rating => (
            <button
              key={rating}
              className={`${styles.ratingButton} ${
                current?.state.rating === rating ? styles.selectedControl : ''
              }`}
              onClick={() => void commitTargets({ rating })}
              disabled={busy}
            >
              {rating === 0 ? '0' : `${rating}★`}
            </button>
          ))}
        </div>
        <div className={styles.controlGroup}>
          <span className={styles.controlLabel}>{t('culling.color')}</span>
          {COLOR_LABELS.map(label => (
            <button
              key={label.value}
              className={`${styles.colorButton} ${
                current?.state.colorLabel === label.value ? styles.selectedControl : ''
              }`}
              style={{ '--label-color': label.color } as React.CSSProperties}
              title={t(label.labelKey)}
              aria-label={t('culling.colorLabel', { label: t(label.labelKey) })}
              onClick={() => void commitTargets({ colorLabel: label.value })}
              disabled={busy}
            >
              {label.value === 'None' ? '×' : ''}
            </button>
          ))}
        </div>
        {currentGroupAssets.length > 1 && (
          <div className={styles.groupDecision}>
            <span className={styles.controlLabel}>
              {t('culling.similarGroup', { count: currentGroupAssets.length })}
            </span>
            <button
              className={styles.groupAction}
              onClick={() => void keepInGroupRejectRest([current.photo.id])}
              disabled={busy}
            >
              {t('culling.keepCurrent')}
            </button>
            <button
              className={styles.groupActionSecondary}
              onClick={() => void keepInGroupRejectRest([...selectedIds])}
              disabled={
                busy ||
                selectedIds.size < 1 ||
                selectedIds.size >= currentGroupAssets.length ||
                [...selectedIds].some(
                  photoId => !currentGroupAssets.some(asset => asset.photo.id === photoId),
                )
              }
              title={t('culling.keepSelectedHint')}
            >
              {selectedIds.size > 0 ? t('culling.keepSelected', { count: selectedIds.size }) : t('culling.keepSelectedShortcut')}
            </button>
            <span className={styles.groupHint}>{t('culling.othersRejected')}</span>
          </div>
        )}
        {selectedIds.size > 0 && (
          <button onClick={() => setSelectedIds(new Set())}>{t('culling.clearSelection')}</button>
        )}
      </div>
      {message && <div className={styles.feedbackMessage} role="status">{message}</div>}
    </div>
  )
}

function ScopeControls({
  scope,
  setScope,
}: {
  scope: CullingScope
  setScope: (scope: CullingScope) => void
}) {
  const { t } = useTranslation()
  const options: Array<[CullingScope, TranslationKey]> = [
    ['all', 'culling.scopeAll'],
    ['filtered', 'culling.scopeFiltered'],
    ['similarity_group', 'culling.scopeSimilarityGroup'],
  ]
  return (
    <div className={styles.segmented}>
      {options.map(([value, labelKey]) => (
        <button
          key={value}
          className={scope === value ? styles.active : ''}
          onClick={() => setScope(value)}
        >
          {t(labelKey)}
        </button>
      ))}
    </div>
  )
}

function FilterControls({
  filters,
  setFilters,
}: {
  filters: CullingFilters
  setFilters: React.Dispatch<React.SetStateAction<CullingFilters>>
}) {
  const { t } = useTranslation()
  return (
    <>
      <label className={styles.toggle}>
        <input
          type="checkbox"
          checked={Boolean(filters.unreviewedOnly)}
          onChange={event => setFilters(value => ({
            ...value,
            unreviewedOnly: event.target.checked,
          }))}
        />
        {t('culling.onlyUnreviewed')}
      </label>
      <select
        className={styles.select}
        value={filters.pickStates?.[0] ?? ''}
        onChange={event => setFilters(value => ({
          ...value,
          pickStates: event.target.value
            ? [event.target.value as NonNullable<CullingFilters['pickStates']>[number]]
            : undefined,
        }))}
      >
        <option value="">{t('culling.statusAll')}</option>
        <option value="picked">{t('culling.statusPicked')}</option>
        <option value="rejected">{t('culling.statusRejected')}</option>
        <option value="unreviewed">{t('culling.statusUnreviewed')}</option>
      </select>
      <select
        className={styles.select}
        value={filters.ratings?.[0] ?? ''}
        onChange={event => setFilters(value => ({
          ...value,
          ratings: event.target.value === ''
            ? undefined
            : [Number(event.target.value)],
        }))}
      >
        <option value="">{t('culling.ratingAll')}</option>
        {[0, 1, 2, 3, 4, 5].map(rating => (
          <option key={rating} value={rating}>
            {rating === 0 ? t('culling.ratingNone') : t('culling.ratingValue', { count: rating })}
          </option>
        ))}
      </select>
      <select
        className={styles.select}
        value={filters.colorLabels?.[0] ?? ''}
        onChange={event => setFilters(value => ({
          ...value,
          colorLabels: event.target.value
            ? [event.target.value as CaptureOneColorLabel]
            : undefined,
        }))}
      >
        <option value="">{t('culling.colorAll')}</option>
        {COLOR_LABELS.map(label => (
          <option key={label.value} value={label.value}>{t(label.labelKey)}</option>
        ))}
      </select>
      <select
        className={styles.select}
        value={filters.qualityStatus ?? ''}
        onChange={event => setFilters(value => ({
          ...value,
          qualityStatus: event.target.value
            ? event.target.value as CullingFilters['qualityStatus']
            : undefined,
        }))}
      >
        <option value="">{t('culling.analysisAll')}</option>
        <option value="analysed">{t('culling.analysisDone')}</option>
        <option value="unanalysed">{t('culling.analysisNotDone')}</option>
        <option value="failed">{t('culling.analysisFailed')}</option>
      </select>
      <label className={styles.toggle}>
        <input
          type="checkbox"
          checked={Boolean(filters.metadataConflictOnly)}
          onChange={event => setFilters(value => ({
            ...value,
            metadataConflictOnly: event.target.checked,
          }))}
        />
        {t('culling.onlyConflict')}
      </label>
      <button onClick={() => setFilters({})}>{t('culling.reset')}</button>
    </>
  )
}
