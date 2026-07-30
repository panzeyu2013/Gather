import React, { useState, useMemo } from 'react'
import { useFaceKwStore } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'
import WritebackReport from '../../components/WritebackReport/WritebackReport'
import type { WritebackResult, WritebackItem } from '@gather/shared'
import { useQuery } from '@tanstack/react-query'
import styles from './StepWriteback.module.css'

export default function StepWriteback() {
  const { setWritebackReport, writebackReport, writebackRunning, setWritebackRunning, sessionId } = useFaceKwStore()
  const { data: clusters = [] } = useQuery({
    queryKey: ['face-clusters', sessionId],
    queryFn: async () => (await faceKwApi.getClusters(sessionId!)).map(cluster => ({
      ...cluster,
      binding: cluster.binding ?? null,
    })),
    enabled: Boolean(sessionId),
  })
  const [writebackResult, setWritebackResult] = useState<WritebackResult | null>(null)
  const [failedItems, setFailedItems] = useState<WritebackItem[]>([])
  const [syncConfirmed, setSyncConfirmed] = useState(false)

  const boundClusters = useMemo(() => clusters.filter((c) => c.binding), [clusters])
  const unboundClusters = useMemo(() => clusters.filter((c) => !c.binding), [clusters])

  const totalAffected = useMemo(
    () => boundClusters.reduce((sum, c) => sum + c.size, 0),
    [boundClusters],
  )

  const handlePreview = async () => {
    if (!sessionId) return
    try {
      const preview = await faceKwApi.previewWriteback(sessionId)
      setWritebackReport(sessionId, `预览: ${preview.totalCount} 项, ${preview.affectedPhotos} 张照片受影响`)
    } catch (e) {
      setWritebackReport(sessionId, `预览失败: ${(e as Error).message}`)
    }
  }

  const handleExecute = async () => {
    if (!sessionId) return
    setWritebackRunning(sessionId, true)
    try {
      const preview = await faceKwApi.previewWriteback(sessionId)
      const result = await faceKwApi.writeback(sessionId, preview.items)
      setWritebackResult(result)
      setFailedItems(result.failedItems)
      setSyncConfirmed(false)
      setWritebackReport(sessionId, `写回完成: ${result.written} 已写入, ${result.failed} 失败, ${result.skipped} 已跳过`)
    } catch (e) {
      setWritebackReport(sessionId, `写回失败: ${(e as Error).message}`)
    } finally {
      setWritebackRunning(sessionId, false)
    }
  }

  const handleRetryFailed = async () => {
    if (!sessionId) return
    setWritebackRunning(sessionId, true)
    try {
      setWritebackReport(sessionId, '正在重试失败项...')
      const failedOnly = failedItems
      const result = await faceKwApi.writeback(sessionId, failedOnly)
      setWritebackResult(result)
      if (result.failed === 0) setFailedItems([])
    } catch (e) {
      setWritebackReport(sessionId, `重试失败: ${(e as Error).message}`)
    } finally {
      setWritebackRunning(sessionId, false)
    }
  }

  const handleConfirmSync = async () => {
    if (!sessionId) return
    try {
      await faceKwApi.confirmSync(sessionId)
      setSyncConfirmed(true)
      setWritebackReport(sessionId, '同步已确认。')
    } catch (e) {
      setWritebackReport(sessionId, `确认失败: ${(e as Error).message}`)
    }
  }

  const handleCleanup = async () => {
    if (!sessionId) return
    try {
      const result = await faceKwApi.cleanup(sessionId)
      setWritebackReport(sessionId, `清理完成: ${result.deletedCount} 个文件已删除`)
    } catch (e) {
      setWritebackReport(sessionId, `清理失败: ${(e as Error).message}`)
    }
  }

  return (
    <div className={styles.page}>
      <h2 className={styles.title}>写回 Capture One 关键词</h2>

      <div className={styles.stats}>
        <div className={styles.statCard}>
          <div className={styles.statValueAccent}>{boundClusters.length}</div>
          <div className={styles.statLabel}>已绑定聚类</div>
        </div>
        <div className={styles.statCard}>
          <div className={styles.statValue}>{totalAffected}</div>
          <div className={styles.statLabel}>受影响照片</div>
        </div>
        <div className={styles.statCard}>
          <div className={styles.statValueWarning}>{unboundClusters.length}</div>
          <div className={styles.statLabel}>未绑定并跳过</div>
        </div>
      </div>

      <div className={styles.preview}>
        {boundClusters.map((c) => (
          <div key={c.id} className={styles.cluster}>
            <div className={styles.clusterTitle}>
              {c.binding!.roleName} ({c.size} 张照片)
              <span className={styles.clusterKeywords}>
                {c.binding!.keywords.join(', ')}
              </span>
            </div>
            {c.members.slice(0, 5).map((m, idx) => (
              <div key={idx} className={styles.memberName}>{m.filename}</div>
            ))}
            {c.members.length > 5 && (
              <div className={styles.more}>…及其他 {c.members.length - 5} 张</div>
            )}
          </div>
        ))}
        {boundClusters.length === 0 && (
          <div className={styles.empty}>
            没有已绑定的聚类可写回。请先绑定聚类。
          </div>
        )}
      </div>

      <div className={styles.actions}>
        <button
          type="button"
          onClick={() => void handlePreview()}
          className={styles.secondaryButton}
        >
          预览
        </button>
        <button
          type="button"
          onClick={() => void handleExecute()}
          disabled={boundClusters.length === 0 || writebackRunning}
          className={styles.primaryButton}
        >
          {writebackRunning ? '写入中...' : '执行写回'}
        </button>
      </div>

      {writebackReport && <WritebackReport
        result={writebackResult}
        failedItems={failedItems}
        onRetryFailed={handleRetryFailed}
        onConfirmSync={handleConfirmSync}
        onCleanup={syncConfirmed ? handleCleanup : undefined}
      />}
    </div>
  )
}
