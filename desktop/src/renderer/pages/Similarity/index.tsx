import React, { useState, useEffect } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { similarityApi, type SimilarityResult } from '../../api/similarity'
import { useSimilarityStore } from '../../stores/similarityStore'
import ProgressBar from '../../components/ProgressBar/ProgressBar'
import type { SimilarityGroup, SimilarityImage } from '@gather/shared'
import styles from './Similarity.module.css'

function ThumbnailImage({ path, className }: { path: string; className?: string }) {
  const [src, setSrc] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    similarityApi.getThumbnail(path).then((base64) => {
      if (!cancelled) {
        setSrc(`data:image/jpeg;base64,${base64}`)
      }
    }).catch(() => {
      if (!cancelled) setSrc(null)
    })
    return () => { cancelled = true }
  }, [path])

  const filename = path.split(/[/\\]/).pop() ?? path

  if (!src) {
    return (
      <div className={className ?? styles.thumbPlaceholder}>
        <span>{filename}</span>
      </div>
    )
  }

  return <img src={src} alt={filename} className={className} />
}

function AnalysisPanel({ sessionId, result }: { sessionId: string; result: SimilarityResult | null }) {
  const queryClient = useQueryClient()
  const { threshold, minGroupSize, isAnalyzing, setThreshold, setMinGroupSize, setIsAnalyzing, progressCurrent, progressTotal, progressMessage } =
    useSimilarityStore()

  const analyzeMutation = useMutation({
    mutationFn: () => similarityApi.analyze(sessionId, threshold, minGroupSize),
    onSuccess: () => {
      setIsAnalyzing(false)
      queryClient.invalidateQueries({ queryKey: ['similarity', sessionId] })
    },
    onError: () => {
      setIsAnalyzing(false)
    },
  })

  const reclusterMutation = useMutation({
    mutationFn: () => similarityApi.recluster(sessionId, threshold, minGroupSize),
    onSuccess: (data) => {
      queryClient.setQueryData(['similarity', sessionId], data)
    },
  })

  const handleAnalyze = () => {
    setIsAnalyzing(true)
    analyzeMutation.mutate()
  }

  return (
    <div className={styles.panel}>
      <h2 className={styles.panelTitle}>分析控制</h2>

      <div className={styles.controlRow}>
        <label className={styles.controlLabel}>
          Threshold: <strong>{threshold}</strong>
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
          <span>threshold={result.stats.threshold}</span>
        </div>
      )}
    </div>
  )
}

function GroupCard({ group }: { group: SimilarityGroup }) {
  const [expanded, setExpanded] = useState(false)
  const rep = group.images.find((img) => img.representative) ?? group.images[0]

  return (
    <div className={styles.groupCard}>
      <div className={styles.groupHeader} onClick={() => setExpanded(!expanded)}>
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

function GroupGrid({ result }: { result: SimilarityResult }) {
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
        <GroupCard key={group.id} group={group} />
      ))}
    </div>
  )
}

export default function Similarity() {
  const { sessionId } = useParams<{ sessionId: string }>()

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
      {result && <GroupGrid result={result} />}
    </div>
  )
}
