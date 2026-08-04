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
import styles from './Culling.module.css'

const COLOR_LABELS: Array<{
  value: CaptureOneColorLabel
  label: string
  color: string
}> = [
  { value: 'None', label: '无', color: '#777' },
  { value: 'Red', label: '红', color: '#ef5350' },
  { value: 'Orange', label: '橙', color: '#ff9800' },
  { value: 'Yellow', label: '黄', color: '#fdd835' },
  { value: 'Green', label: '绿', color: '#4caf50' },
  { value: 'Blue', label: '蓝', color: '#42a5f5' },
  { value: 'Pink', label: '粉', color: '#ec407a' },
  { value: 'Purple', label: '紫', color: '#ab47bc' },
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

function syncLabel(summary?: MetadataSyncSummary): string {
  if (!summary || summary.items.length === 0) return 'XMP 已同步'
  if (summary.conflict > 0) return `${summary.conflict} 个 XMP 冲突`
  if (summary.failed > 0) return `${summary.failed} 个 XMP 写入失败`
  if (summary.pending + summary.writing > 0) {
    return `${summary.pending + summary.writing} 个 XMP 等待写入`
  }
  if (summary.written > 0) return `${summary.written} 个 XMP 已写入，等待 Capture One 加载`
  if (summary.synced > 0) return `${summary.synced} 个 XMP 已确认加载`
  return 'XMP 已同步'
}

function valueLabel(value: unknown): string {
  if (Array.isArray(value)) return value.join('、') || '空'
  if (value === '' || value === undefined || value === null) return '空'
  return String(value)
}

function sourceLabel(asset: CullingAsset): string {
  if (asset.metadataSource === 'template') return '模板元数据'
  if (asset.metadataSource === 'face-keyword') return '人脸关键词'
  if (asset.metadataSource === 'similarity') return '相似组关键词'
  if (asset.quality?.status === 'succeeded') return 'AI 技术分析'
  if (asset.state.source === 'imported') return '导入元数据'
  return '人工调整'
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
        <strong>XMP 字段冲突</strong>
        <span title={conflict.xmpPath}>{conflict.xmpPath.split(/[/\\]/).pop()}</span>
      </header>
      {conflict.fields.map(field => (
        <div className={styles.conflictField} key={field.field}>
          <strong>{field.field === 'rating' ? '星级' : field.field === 'label' ? '颜色' : '关键词'}</strong>
          <span title={valueLabel(field.local)}>Gather：{valueLabel(field.local)}</span>
          <span title={valueLabel(field.remote)}>外部：{valueLabel(field.remote)}</span>
          <select
            value={choices[field.field] ?? 'keep_local'}
            onChange={event => setChoices(current => ({
              ...current,
              [field.field]: event.target.value as MetadataConflictChoice,
            }))}
          >
            <option value="keep_local">保留 Gather</option>
            <option value="use_remote">采用外部值</option>
          </select>
        </div>
      ))}
      <footer>
        <span>{conflicts.length > 1 ? `还有 ${conflicts.length - 1} 个冲突` : '这是最后一个冲突'}</span>
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
          {resolving ? '处理中…' : '应用并继续写入'}
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
  const [broken, setBroken] = useState(false)
  if (broken) {
    return <span className={styles.thumbBroken}>离线</span>
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
  const alignX = faceAlign && face ? (0.5 - faceX) * 100 : 0
  const alignY = faceAlign && face ? (0.5 - faceY) * 100 : 0
  const scale = faceAlign && face ? Math.max(2, transform.scale) : transform.scale
  return (
    <div className={styles.compareCell}>
      {broken ? (
        <div className={styles.viewerBroken}>
          <p>文件离线或无法解码</p>
          <p className={styles.viewerBrokenHint}>可在全局图库中为离线存储卷重新定位</p>
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
        <span className={styles.sourceLabel}>{sourceLabel(asset)}</span>
        <span>{asset.state.rating > 0 ? `${asset.state.rating}★` : '未评级'}</span>
      </div>
      {asset.state.pickState !== 'unreviewed' && (
        <span className={`${styles.pickBadge} ${
          asset.state.pickState === 'picked' ? styles.picked : styles.rejected
        }`}>
          {asset.state.pickState === 'picked' ? '保留' : '淘汰'}
        </span>
      )}
      {faceAlign && !face && <span className={styles.noFaceBadge}>未检测到人脸</span>}
      {asset.quality && (
        <span className={styles.qualityBadge} title={
          asset.quality.status === 'failed'
            ? asset.quality.errorMessage ?? '质量分析失败'
            : `AI 技术分析：清晰度 ${Math.round((asset.quality.subjectSharpness ?? asset.quality.sharpness) * 100)}%，曝光 ${Math.round(asset.quality.exposure * 100)}%`
        }>
          {asset.quality.status === 'failed' ? '分析失败' : `质量 ${Math.round(asset.quality.score * 100)}`}
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
  const filmstripRef = useRef<HTMLDivElement>(null)

  const assetQueryKey = useMemo(
    () => ['culling', 'assets', sessionId, scope, filters] as const,
    [filters, scope, sessionId],
  )
  const { data, isLoading, refetch } = useQuery({
    queryKey: assetQueryKey,
    queryFn: () => cullingApi.list(sessionId!, scope, filters),
    enabled: Boolean(sessionId),
  })
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
    refetchInterval: 1_000,
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
      setMessage(dryRun ? '分组预览已生成；确认后可保存' : 'Burst/Scene 分组已保存')
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Burst/Scene 分析失败')
    } finally {
      setNavigationBusy(false)
    }
  }, [sessionId])

  const jumpToNavigationGroup = useCallback((group: NavigationGroup) => {
    const first = group.photoIds[0]
    const index = assets.findIndex(asset => asset.photo.id === first)
    if (index >= 0) {
      setCurrentIndex(index)
      setTransform({ scale: 1, x: 0, y: 0 })
    }
  }, [assets])

  useEffect(() => {
    if (data) setAssets(data)
  }, [data])
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
      setMessage('质量分析完成')
      void refetch()
    } else {
      setMessage(job.errorMessage || '质量分析未完成')
    }
    setQualityJobId(undefined)
  }, [qualityJobId, refetch, runningJobs])
  const conflictCountRef = useRef<number>(0)
  conflictCountRef.current = syncSummary?.conflict ?? initialSync?.conflict ?? 0
  useEvent('culling:sync-status', (payload) => {
    const next = payload as MetadataSyncSummary
    if (next.sessionId !== sessionId) return
    const previousConflicts = conflictCountRef.current
    setSyncSummary(next)
    setAssets(current => current.map(asset => {
      const item = next.items.find(candidate => candidate.xmpPath === asset.xmpPath)
      return item ? { ...asset, syncStatus: item.status } : asset
    }))
    // Path summaries are emitted per xmp_path, so one flush can raise the
    // conflict count 1..N across several events; refetch on any change.
    if (next.conflict > 0 && next.conflict !== previousConflicts) {
      void refetchConflicts()
    }
  }, Boolean(sessionId))
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
  }, [sessionId])

  const current = assets[currentIndex]
  const assetById = useMemo(
    () => new Map(assets.map(asset => [asset.photo.id, asset])),
    [assets],
  )
  const currentGroupAssets = useMemo(() => {
    if (!current?.similarityGroupId) return current ? [current] : []
    return assets.filter(asset => asset.similarityGroupId === current.similarityGroupId)
  }, [assets, current])
  const comparisonAssets = useMemo(() => {
    if (!current) return []
    const pool = current.similarityGroupId ? currentGroupAssets : assets
    const others = pool.filter(asset => asset.photo.id !== current.photo.id)
    return [current, ...others].slice(0, compareCount)
  }, [assets, compareCount, current, currentGroupAssets])
  const stripStart = Math.max(0, currentIndex - 50)
  const stripAssets = assets.slice(stripStart, stripStart + 101)
  const effectiveTargetIds = selectedIds.size > 0
    ? [...selectedIds]
    : current ? [current.photo.id] : []

  useEffect(() => {
    if (!current) return
    const preload = assets
      .slice(currentIndex, currentIndex + 8)
      .map(asset => asset.photo.filepath)
    void imageApi.preloadPreviews(preload, 2560).catch(() => undefined)
  }, [assets, current, currentIndex])

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
    const nextAssets = refreshed.data ?? []
    setAssets(nextAssets)
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
    setCurrentIndex(index => Math.min(index + 1, Math.max(0, assets.length - 1)))
    setTransform({ scale: 1, x: 0, y: 0 })
  }, [assets.length])

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
      setMessage(error instanceof Error ? error.message : '更新失败')
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
      setMessage(error instanceof Error ? error.message : '批量更新失败')
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
        ? `撤销未完整执行，历史记录已重置：${error.message}`
        : '撤销未完整执行，历史记录已重置')
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
        ? `重做未完整执行，历史记录已重置：${error.message}`
        : '重做未完整执行，历史记录已重置')
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
      const allAssets = await cullingApi.list(sessionId, 'all', {})
      const fullGroup = allAssets.filter(
        asset => asset.similarityGroupId === current.similarityGroupId,
      )
      const groupIds = new Set(fullGroup.map(asset => asset.photo.id))
      if (
        fullGroup.length < 2 ||
        keepPhotoIds.some(photoId => !groupIds.has(photoId))
      ) {
        throw new Error('相似组已变化，请刷新后重试')
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
      await refetch()
      if (autoAdvance) {
        const nextIndex = assets.findIndex(
          (asset, index) =>
            index > currentIndex &&
            asset.similarityGroupId !== current.similarityGroupId,
        )
        if (nextIndex >= 0) {
          setCurrentIndex(nextIndex)
          setTransform({ scale: 1, x: 0, y: 0 })
        }
      }
    } catch (error) {
      setMessage(error instanceof Error ? error.message : '组内批量操作失败')
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
    queryClient,
    refetch,
    sessionId,
  ])

  const flush = useCallback(async () => {
    if (!sessionId) return
    setBusy(true)
    try {
      setSyncSummary(await cullingApi.flush(sessionId))
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'XMP 写入失败')
    } finally {
      setBusy(false)
    }
  }, [sessionId])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
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
        setTransform({ scale: 1, x: 0, y: 0 })
      } else if (event.key === 'ArrowRight') {
        event.preventDefault()
        advance()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [advance, busy, commitTargets, redo, undo])

  if (!sessionId) {
    return <div className={styles.emptyState}>未选择工作区</div>
  }
  if (isLoading) {
    return <div className={styles.emptyState}>正在载入挑片工作台…</div>
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
          当前范围没有照片。切换到“全部照片”或清除筛选条件。
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
            {navigationBusy ? '分析中…' : '保存 Burst/Scene 分组'}
          </button>
          <button onClick={() => void analyzeNavigation(true)} disabled={navigationBusy}>
            预览分组
          </button>
          <button
            disabled={Boolean(qualityJobId)}
            onClick={() => {
              void qualityApi.analyze(sessionId).then(job => {
                setQualityJobId(job.id)
                setMessage('质量分析已加入任务队列')
              }).catch(error => {
                setMessage(error instanceof Error ? error.message : '无法启动质量分析')
              })
            }}
          >
            {qualityJobId ? '质量分析中…' : '分析技术质量'}
          </button>
          {navigationGroups.length > 0 && (
            <select className={styles.select} defaultValue="" onChange={event => {
              setSelectedNavigationGroupId(event.target.value)
              const group = navigationGroups.find(item => item.id === event.target.value)
              if (group) jumpToNavigationGroup(group)
            }}>
              <option value="">导航组 ({navigationGroups.length})</option>
              {navigationGroups.map(group => (
                <option key={group.id} value={group.id}>
                  {group.type === 'burst' ? 'Burst' : 'Scene'} · {group.photoIds.length} 张
                  {group.leadPhotoId ? ` · 推荐 ${group.photoIds.indexOf(group.leadPhotoId) + 1}` : ''}
                </option>
              ))}
            </select>
          )}
          {selectedNavigationGroupId && (
            <>
              <button
                title={navigationGroups.find(group => group.id === selectedNavigationGroupId)?.explanation}
                onClick={() => {
                  const group = navigationGroups.find(item => item.id === selectedNavigationGroupId)
                  if (!group || !current || group.photoIds.indexOf(current.photo.id) <= 0) {
                    setMessage('请先定位到组内非首张照片')
                    return
                  }
                  void navigationApi.split(sessionId, group.id, current.photo.id)
                    .then(setNavigationGroups)
                    .catch(error => setMessage(error instanceof Error ? error.message : '拆分失败'))
                }}
              >
                从当前照片拆分
              </button>
              <button
                onClick={() => {
                  const index = navigationGroups.findIndex(group => group.id === selectedNavigationGroupId)
                  const selected = navigationGroups[index]
                  const previous = navigationGroups.slice(0, index).reverse()
                    .find(group => group.type === selected?.type)
                  if (!selected || !previous) {
                    setMessage('没有可合并的前一个同类组')
                    return
                  }
                  void navigationApi.merge(sessionId, [previous.id, selected.id])
                    .then(setNavigationGroups)
                    .catch(error => setMessage(error instanceof Error ? error.message : '合并失败'))
                }}
              >
                与前组合并
              </button>
            </>
          )}
          <label className={styles.toggle}>
            <input
              type="checkbox"
              checked={autoAdvance}
              onChange={event => setAutoAdvance(event.target.checked)}
            />
            自动前进
          </label>
          <div className={styles.segmented}>
            {([1, 2, 4] as const).map(count => (
              <button
                key={count}
                className={compareCount === count ? styles.active : ''}
                onClick={() => {
                  setCompareCount(count)
                  setTransform({ scale: 1, x: 0, y: 0 })
                }}
              >
                {count === 1 ? '单图' : `${count} 图`}
              </button>
            ))}
          </div>
          <label className={styles.toggle}>
            <input
              type="checkbox"
              checked={faceAlign}
              onChange={event => {
                setFaceAlign(event.target.checked)
                setTransform({ scale: 1, x: 0, y: 0 })
              }}
            />
            人脸对齐
          </label>
          <div className={styles.historyActions}>
            <button
              className={styles.iconButton}
              onClick={() => void undo()}
              disabled={!undoStack.length || busy}
              title="撤销（⌘Z）"
              aria-label="撤销"
            >
              ↶
            </button>
            <button
              className={styles.iconButton}
              onClick={() => void redo()}
              disabled={!redoStack.length || busy}
              title="重做（⇧⌘Z）"
              aria-label="重做"
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
          setTransform(value => ({
            ...value,
            scale: Math.max(1, Math.min(8, value.scale * (event.deltaY < 0 ? 1.15 : 0.87))),
          }))
        }}
        onPointerDown={event => {
          event.currentTarget.setPointerCapture(event.pointerId)
          dragRef.current = {
            x: event.clientX,
            y: event.clientY,
            originX: transform.x,
            originY: transform.y,
          }
        }}
        onPointerMove={event => {
          if (!dragRef.current) return
          setTransform(value => ({
            ...value,
            x: dragRef.current!.originX + event.clientX - dragRef.current!.x,
            y: dragRef.current!.originY + event.clientY - dragRef.current!.y,
          }))
        }}
        onPointerUp={() => { dragRef.current = null }}
        onDoubleClick={() => setTransform({ scale: 1, x: 0, y: 0 })}
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
            setTransform({ scale: 1, x: 0, y: 0 })
          }}
          disabled={currentIndex === 0}
          aria-label="上一张照片"
        >
          ‹
        </button>
        <button
          className={`${styles.navButton} ${styles.next}`}
          onClick={advance}
          disabled={currentIndex === assets.length - 1}
          aria-label="下一张照片"
        >
          ›
        </button>
        <div className={styles.zoomHint}>
          {Math.round((faceAlign ? Math.max(2, transform.scale) : transform.scale) * 100)}%
          · 滚轮缩放 · 拖动平移 · 双击复位
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
        <span className={styles.positionCount}>{currentIndex + 1} / {assets.length}</span>
        <span className={styles.keptStat}>保留 {summary?.kept ?? 0}</span>
        <span className={styles.rejectedStat}>淘汰 {summary?.rejected ?? 0}</span>
        <span>未处理 {summary?.pending ?? assets.length}</span>
        {current?.linkedVariantCount && current.linkedVariantCount > 1 && (
          <span className={styles.linkedNotice}>
            同名 RAW/JPEG 共用 XMP，星级和颜色将同步到 {current.linkedVariantCount} 个条目
          </span>
        )}
        <span className={`${styles.syncState} ${
          (syncSummary?.failed ?? 0) + (syncSummary?.conflict ?? 0) > 0
            ? styles.syncError
            : ''
        }`}>
          {syncLabel(syncSummary)}
        </span>
        <button onClick={() => void flush()} disabled={busy}>立即写入 XMP</button>
        {(syncSummary?.written ?? 0) > 0 && (
          <button
            disabled={busy}
            onClick={() => {
              setBusy(true)
              void window.gather.reloadMetadata()
                .then(() => setMessage('已在 Capture One 中加载元数据，返回后请确认同步'))
                .catch(error => addToast('error', error instanceof Error ? error.message : '加载元数据失败'))
                .finally(() => setBusy(false))
            }}
          >
            在 Capture One 中加载元数据
          </button>
        )}
        {(syncSummary?.written ?? 0) > 0 && (
          <span className={styles.syncHint}>先在 Capture One 中 Load Metadata，再返回 Gather 确认同步</span>
        )}
        {(syncSummary?.failed ?? 0) > 0 && (
          <button
            onClick={() => {
              if (!sessionId) return
              setBusy(true)
              void cullingApi.retrySync(sessionId)
                .then(setSyncSummary)
                .catch(error => setMessage(error instanceof Error ? error.message : '重试失败'))
                .finally(() => setBusy(false))
            }}
          >
            重试失败项
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
                .catch(error => setMessage(error instanceof Error ? error.message : '确认失败'))
                .finally(() => setBusy(false))
            }}
          >
            已在 Capture One 加载
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
                    setMessage('已保留当前 XMP，并结束本次同步')
                    setSyncSummary(summary)
                  })
                  .catch(error => setMessage(error instanceof Error ? error.message : '结束同步失败'))
                  .finally(() => setBusy(false))
              }}
            >
              保留 XMP 并结束
            </button>
            <button
              onClick={() => {
                if (!sessionId) return
                setBusy(true)
                void cullingApi.cleanup(sessionId)
                  .then(result => {
                    setMessage(result.errors.length > 0
                      ? `有 ${result.errors.length} 个 XMP 未清理：${result.errors[0]}`
                      : `已清理 ${result.deletedCount} 个临时 XMP`)
                    return cullingApi.syncStatus(sessionId)
                  })
                  .then(setSyncSummary)
                  .catch(error => setMessage(error instanceof Error ? error.message : '清理失败'))
                  .finally(() => setBusy(false))
              }}
            >
              恢复原 XMP
            </button>
          </>
        )}
      </div>

      <div className={styles.filmstrip} ref={filmstripRef}>
        <div className={styles.stripHeader}>
          <span>胶片</span>
          <span>{assets.length}</span>
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
                    next.has(asset.photo.id)
                      ? next.delete(asset.photo.id)
                      : next.add(asset.photo.id)
                    return next
                  })
                } else {
                  setCurrentIndex(index)
                  setTransform({ scale: 1, x: 0, y: 0 })
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
      </div>

      <div className={styles.controls}>
        <div className={styles.panelTitle}>挑片工具</div>
        <div className={styles.controlGroup}>
          <span className={styles.controlLabel}>
            {selectedIds.size > 0 ? `批量 ${selectedIds.size} 张` : '当前照片'}
          </span>
          <div className={styles.decisionBar}>
            <button
              className={`${styles.decisionButton} ${styles.pickButton}`}
              onClick={() => void commitTargets({ pickState: 'picked' })}
              disabled={busy}
              aria-label="保留 P"
            >
              <span className={styles.decisionIcon}>✓</span>
              <span>保留</span>
              <span className={styles.shortcut}>P</span>
            </button>
            <button
              className={`${styles.decisionButton} ${styles.rejectButton}`}
              onClick={() => void commitTargets({ pickState: 'rejected' })}
              disabled={busy}
              aria-label="淘汰 X"
            >
              <span className={styles.decisionIcon}>×</span>
              <span>淘汰</span>
              <span className={styles.shortcut}>X</span>
            </button>
            <button
              className={`${styles.decisionButton} ${styles.clearButton}`}
              onClick={() => void commitTargets({ pickState: 'unreviewed' }, false)}
              disabled={busy}
              aria-label="清除 U"
            >
              <span className={styles.decisionIcon}>○</span>
              <span>清除</span>
              <span className={styles.shortcut}>U</span>
            </button>
          </div>
        </div>
        <div className={styles.controlGroup}>
          <span className={styles.controlLabel}>星级</span>
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
          <span className={styles.controlLabel}>颜色</span>
          {COLOR_LABELS.map(label => (
            <button
              key={label.value}
              className={`${styles.colorButton} ${
                current?.state.colorLabel === label.value ? styles.selectedControl : ''
              }`}
              style={{ '--label-color': label.color } as React.CSSProperties}
              title={label.label}
              aria-label={`颜色：${label.label}`}
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
              相似组 · {currentGroupAssets.length} 张
            </span>
            <button
              className={styles.groupAction}
              onClick={() => void keepInGroupRejectRest([current.photo.id])}
              disabled={busy}
            >
              保留当前 1 张
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
              title="按住 ⌘ 或 Ctrl 在胶片中选择要保留的照片"
            >
              保留已选 {selectedIds.size || 'K'} 张
            </button>
            <span className={styles.groupHint}>其余照片自动淘汰</span>
          </div>
        )}
        {selectedIds.size > 0 && (
          <button onClick={() => setSelectedIds(new Set())}>取消选择</button>
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
  return (
    <div className={styles.segmented}>
      {([
        ['all', '全部照片'],
        ['filtered', '筛选'],
        ['similarity_group', '相似组'],
      ] as Array<[CullingScope, string]>).map(([value, label]) => (
        <button
          key={value}
          className={scope === value ? styles.active : ''}
          onClick={() => setScope(value)}
        >
          {label}
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
        仅未处理
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
        <option value="">全部状态</option>
        <option value="picked">保留</option>
        <option value="rejected">淘汰</option>
        <option value="unreviewed">未处理</option>
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
        <option value="">全部星级</option>
        {[0, 1, 2, 3, 4, 5].map(rating => (
          <option key={rating} value={rating}>
            {rating === 0 ? '未评级' : `${rating} 星`}
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
        <option value="">全部颜色</option>
        {COLOR_LABELS.map(label => (
          <option key={label.value} value={label.value}>{label.label}</option>
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
        <option value="">全部分析状态</option>
        <option value="analysed">已分析</option>
        <option value="unanalysed">未分析</option>
        <option value="failed">分析失败</option>
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
        仅 XMP 冲突
      </label>
      <button onClick={() => setFilters({})}>重置</button>
    </>
  )
}
