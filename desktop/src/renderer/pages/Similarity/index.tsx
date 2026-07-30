import React, { useState, useEffect } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { similarityApi, type SimilarityResult } from '../../api/similarity'
import { imageApi } from '../../api/image'
import { useSimilarityStore } from '../../stores/similarityStore'
import ProgressBar from '../../components/ProgressBar/ProgressBar'
import WritebackReport from '../../components/WritebackReport/WritebackReport'
import type { SimilarityGroup, SimilarityImage, WritebackItem, WritebackPreview, WritebackResult } from '@gather/shared'
import styles from './Similarity.module.css'

function ThumbnailImage({ path, className }: { path: string; className?: string }) {
  const filename = path.split(/[/\\]/).pop() ?? path
  return <img src={imageApi.thumbnailUrl(path, 256)} alt={filename} className={className} />
}

function AnalysisPanel({ sessionId, result }: { sessionId: string; result: SimilarityResult | null }) {
  const queryClient = useQueryClient()
  const {
    threshold,
    minGroupSize,
    groupingMode,
    isAnalyzing,
    setThreshold,
    setMinGroupSize,
    setGroupingMode,
    setIsAnalyzing,
    progressCurrent,
    progressTotal,
    progressMessage,
  } =
    useSimilarityStore()

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

  const reclusterMutation = useMutation({
    mutationFn: () => similarityApi.recluster(
      sessionId,
      threshold,
      minGroupSize,
      groupingMode,
    ),
    onSuccess: (data) => {
      queryClient.setQueryData(['similarity', sessionId], data)
    },
  })

  const handleAnalyze = () => {
    setIsAnalyzing(true)
    analyzeMutation.mutate()
  }

  useEffect(() => {
    if (result?.stats.groupingMode) {
      setGroupingMode(result.stats.groupingMode)
    }
  }, [result?.stats.groupingMode, setGroupingMode])

  return (
    <div className={styles.panel}>
      <h2 className={styles.panelTitle}>分析控制</h2>

      <div className={styles.controlRow}>
        <span className={styles.controlLabel}>分组范围</span>
        <div className={styles.modeSelector}>
          <button
            className={groupingMode === 'sequential' ? styles.modeActive : styles.modeButton}
            onClick={() => setGroupingMode('sequential')}
          >
            <strong>顺序分组</strong>
            <span>只合并导入顺序中连续相似的照片，适合连拍挑片</span>
          </button>
          <button
            className={groupingMode === 'global' ? styles.modeActive : styles.modeButton}
            onClick={() => setGroupingMode('global')}
          >
            <strong>全局分组</strong>
            <span>在整个工作区查找相似照片，允许跨拍摄顺序聚合</span>
          </button>
        </div>
      </div>

      <div className={styles.controlRow}>
        <label className={styles.controlLabel}>
          相似度阈值：<strong>{threshold}</strong>
        </label>
        <input
          type="range"
          min={0}
          max={30}
          value={threshold}
          onChange={(e) => setThreshold(Number(e.target.value))}
          className={styles.slider}
        />
        <span className={styles.rangeHint}>0 (严格) — 30 (宽松)</span>
      </div>

      <div className={styles.controlRow}>
        <label className={styles.controlLabel}>
          最小组大小: <strong>{minGroupSize}</strong>
        </label>
        <input
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
          {isAnalyzing || analyzeMutation.isPending ? '分析中...' : '开始分析'}
        </button>

        {result && (
          <button
            className={styles.reclusterBtn}
            onClick={() => reclusterMutation.mutate()}
            disabled={reclusterMutation.isPending}
          >
            {reclusterMutation.isPending ? '聚类中...' : '重新聚类'}
          </button>
        )}
      </div>

      {(isAnalyzing || analyzeMutation.isPending) && (
        <div className={styles.progressSection}>
          <ProgressBar value={progressCurrent} max={progressTotal} label={progressMessage || '正在计算哈希并聚类...'} />
        </div>
      )}

      {analyzeMutation.isError && (
        <p className={styles.error}>
          错误: {analyzeMutation.error instanceof Error ? analyzeMutation.error.message : '未知错误'}
        </p>
      )}

      {result && result.stats && (
        <div className={styles.stats}>
          <span>{result.stats.totalGroups} 个分组</span>
          <span>{result.stats.totalUngrouped} 未分组</span>
          <span>阈值 {result.stats.threshold}</span>
          <span>
            {result.stats.groupingMode === 'sequential' ? '顺序分组' : '全局分组'}
          </span>
        </div>
      )}
    </div>
  )
}

function GroupCard({
  group,
  selected,
  onSelectedChange,
}: {
  group: SimilarityGroup
  selected: boolean
  onSelectedChange: (selected: boolean) => void
}) {
  const [expanded, setExpanded] = useState(false)
  const rep = group.images.find((img) => img.representative) ?? group.images[0]

  return (
    <div className={styles.groupCard}>
      <div className={styles.groupHeader} onClick={() => setExpanded(!expanded)}>
        <input
          type="checkbox"
          checked={selected}
          onChange={(event) => onSelectedChange(event.target.checked)}
          onClick={(event) => event.stopPropagation()}
          aria-label={`选择 ${group.label}`}
          className={styles.groupCheckbox}
        />
        <ThumbnailImage path={rep.path} className={styles.groupThumb} />
        <div className={styles.groupInfo}>
          <h3 className={styles.groupLabel}>{group.label}</h3>
          <span className={styles.groupCount}>{group.count} 张照片</span>
        </div>
        <span className={styles.expandIcon}>{expanded ? '▾' : '▸'}</span>
      </div>

      {expanded && (
        <div className={styles.groupMembers}>
          {group.images.map((img, i) => (
            <div key={i} className={styles.memberItem}>
              <ThumbnailImage path={img.path} className={styles.memberThumb} />
              <span className={styles.memberName}>
                {img.path.split(/[/\\]/).pop() ?? img.path}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

function GroupGrid({
  result,
  selectedGroupIds,
  onSelectedChange,
}: {
  result: SimilarityResult
  selectedGroupIds: Set<number>
  onSelectedChange: (groupId: number, selected: boolean) => void
}) {
  if (result.groups.length === 0) {
    return (
      <div className={styles.empty}>
        <p>当前参数未找到相似分组。</p>
      </div>
    )
  }

  return (
    <div className={styles.grid}>
      {result.groups.map((group) => (
        <GroupCard
          key={group.id}
          group={group}
          selected={selectedGroupIds.has(group.id)}
          onSelectedChange={(selected) => onSelectedChange(group.id, selected)}
        />
      ))}
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
  const [syncConfirmed, setSyncConfirmed] = useState(false)

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
    setSyncConfirmed(false)
  }, [keywordInput, selectedGroupIds])

  const handlePreview = async () => {
    if (!canPreview) return
    setBusy(true)
    setMessage(null)
    try {
      const nextPreview = await similarityApi.previewWriteback(sessionId, assignments)
      setPreview(nextPreview)
      setMessage(`预览完成：${nextPreview.affectedPhotos} 张照片将合并这些关键词。`)
    } catch (error) {
      setMessage(`预览失败：${error instanceof Error ? error.message : '未知错误'}`)
    } finally {
      setBusy(false)
    }
  }

  const handleWriteback = async () => {
    if (!canPreview) return
    setBusy(true)
    setMessage(null)
    try {
      const currentPreview = preview ?? await similarityApi.previewWriteback(sessionId, assignments)
      setPreview(currentPreview)
      const nextResult = await similarityApi.writeback(sessionId, currentPreview.items)
      setWritebackResult(nextResult)
      setFailedItems(nextResult.failedItems)
      setSyncConfirmed(false)
      setMessage(`XMP 写入完成：成功 ${nextResult.written}，失败 ${nextResult.failed}，跳过 ${nextResult.skipped}。`)
    } catch (error) {
      setMessage(`XMP 写入失败：${error instanceof Error ? error.message : '未知错误'}`)
    } finally {
      setBusy(false)
    }
  }

  const handleRetry = async () => {
    setBusy(true)
    try {
      const nextResult = await similarityApi.retryFailedWriteback(sessionId)
      setWritebackResult(nextResult)
      setFailedItems(nextResult.failedItems)
      setMessage(`重试完成：成功 ${nextResult.written}，失败 ${nextResult.failed}。`)
    } catch (error) {
      setMessage(`重试失败：${error instanceof Error ? error.message : '未知错误'}`)
    } finally {
      setBusy(false)
    }
  }

  const handleConfirmSync = async () => {
    try {
      await similarityApi.confirmSync(sessionId)
      setSyncConfirmed(true)
      setMessage('已确认 Capture One 完成“加载元数据”，现在可以安全清理临时 XMP 变更。')
    } catch (error) {
      setMessage(`确认失败：${error instanceof Error ? error.message : '未知错误'}`)
    }
  }

  const handleCleanup = async () => {
    try {
      const cleanup = await similarityApi.cleanup(sessionId)
      setMessage(`清理完成：已恢复或移除 ${cleanup.deletedCount} 个 sidecar 文件。`)
      setWritebackResult(null)
      setFailedItems([])
      setPreview(null)
    } catch (error) {
      setMessage(`清理失败：${error instanceof Error ? error.message : '未知错误'}`)
    }
  }

  return (
    <div className={styles.writebackPanel}>
      <div className={styles.writebackHeader}>
        <div>
          <h2 className={styles.panelTitle}>批量写入 Capture One 关键词</h2>
          <p className={styles.writebackHint}>
            选择相似分组，关键词会合并写入每张照片旁的 .xmp 文件，不修改原图。
          </p>
        </div>
        <label className={styles.selectAll}>
          <input
            type="checkbox"
            checked={result.groups.length > 0 && selectedGroupIds.size === result.groups.length}
            onChange={(event) => onSelectAll(event.target.checked)}
          />
          全选分组
        </label>
      </div>
      <div className={styles.keywordControls}>
        <input
          className={styles.keywordInput}
          value={keywordInput}
          onChange={(event) => setKeywordInput(event.target.value)}
          placeholder="输入关键词，多个关键词用逗号分隔"
        />
        <button className={styles.reclusterBtn} disabled={!canPreview} onClick={() => void handlePreview()}>
          预览
        </button>
        <button className={styles.analyzeBtn} disabled={!canPreview} onClick={() => void handleWriteback()}>
          {busy ? '处理中...' : '写入 XMP'}
        </button>
      </div>
      <p className={styles.captureOneHint}>
        写入后在 Capture One 中选择这些照片，执行“图像 → 加载元数据”；确认关键词已进入目录后，再点击“确认同步”和“清理”。
      </p>
      {message && <p className={styles.statusMessage}>{message}</p>}
      {writebackResult && (
        <WritebackReport
          result={writebackResult}
          failedItems={failedItems}
          onRetryFailed={() => void handleRetry()}
          onConfirmSync={() => void handleConfirmSync()}
          onCleanup={syncConfirmed ? () => void handleCleanup() : undefined}
        />
      )}
    </div>
  )
}

export default function Similarity() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const [selectedGroupIds, setSelectedGroupIds] = useState<Set<number>>(new Set())
  const resetSimilarityState = useSimilarityStore(state => state.reset)

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

  if (!sessionId) {
      return <div className={styles.page}><p>未选择工作区</p></div>
  }

  if (error) {
    return (
      <div className={styles.page}>
        <p>错误: {error instanceof Error ? error.message : '未知错误'}</p>
      </div>
    )
  }

  return (
    <div className={styles.page}>
      <h1 className={styles.title}>相似度分析</h1>
      <AnalysisPanel sessionId={sessionId} result={result ?? null} />
      {isLoading && <p className={styles.loading}>加载结果中...</p>}
      {result && (
        <>
          <KeywordWritebackPanel
            key={sessionId}
            sessionId={sessionId}
            result={result}
            selectedGroupIds={selectedGroupIds}
            onSelectAll={(selected) => setSelectedGroupIds(
              selected ? new Set(result.groups.map(group => group.id)) : new Set(),
            )}
          />
          <GroupGrid
            result={result}
            selectedGroupIds={selectedGroupIds}
            onSelectedChange={(groupId, selected) => setSelectedGroupIds((current) => {
              const next = new Set(current)
              if (selected) next.add(groupId)
              else next.delete(groupId)
              return next
            })}
          />
        </>
      )}
    </div>
  )
}
