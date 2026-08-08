import React, { useState, useMemo } from 'react'
import { useFaceKwStore } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'
import WritebackReport from '../../components/WritebackReport/WritebackReport'
import { useToastStore } from '../../components/Toast/ToastStore'
import type { WritebackResult, WritebackItem } from '@gather/shared'
import { useQuery } from '@tanstack/react-query'
import styles from './StepWriteback.module.css'

export default function StepWriteback() {
  const setWritebackReport = useFaceKwStore((s) => s.setWritebackReport)
  const writebackReport = useFaceKwStore((s) => s.writebackReport)
  const writebackRunning = useFaceKwStore((s) => s.writebackRunning)
  const setWritebackRunning = useFaceKwStore((s) => s.setWritebackRunning)
  const sessionId = useFaceKwStore((s) => s.sessionId)
  const addToast = useToastStore((s) => s.addToast)
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
  const [previewItems, setPreviewItems] = useState<WritebackItem[]>([])
  const [reloadBusy, setReloadBusy] = useState(false)

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
      setPreviewItems(preview.items)
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
      setPreviewItems(preview.items)
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

  const handleReloadMetadata = async () => {
    if (!sessionId) return
    setReloadBusy(true)
    try {
      await window.gather.reloadMetadata()
      setWritebackReport(sessionId, '已在 Capture One 中加载元数据，返回后请确认同步')
    } catch (e) {
      addToast('error', (e as Error).message || '加载元数据失败')
    } finally {
      setReloadBusy(false)
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

      {previewItems.length > 0 && (
        <div className={styles.xmpPreview} aria-label="XMP 写回预览">
          {previewItems.slice(0, 50).map(item => (
            <div className={styles.xmpPreviewRow} key={item.xmpPath}>
              <strong title={item.xmpPath}>{item.xmpPath.split(/[/\\]/).pop()}</strong>
              <span>
                {(item.preview?.before.keywords ?? []).join('、') || '无关键词'}
                {' → '}
                {(item.preview?.after.keywords ?? item.keywords).join('、') || '无关键词'}
              </span>
              <small>
                {item.preview?.willCreate ? '新建 XMP' : '更新 XMP'}
                {(item.preview?.sharedPhotoCount ?? 1) > 1
                  ? ` · ${item.preview?.sharedPhotoCount} 张共享`
                  : ''}
                {item.preview?.externalChanged ? ' · 检测到外部冲突' : ''}
                {' · 来源：人脸关键词'}
              </small>
            </div>
          ))}
        </div>
      )}

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

      {writebackReport && <>
        <p className={styles.reportMessage}>{writebackReport}</p>
        <WritebackReport
          result={writebackResult}
          failedItems={failedItems}
          onRetryFailed={handleRetryFailed}
          onConfirmSync={handleConfirmSync}
          onCleanup={syncConfirmed ? handleCleanup : undefined}
          disabled={writebackRunning || reloadBusy}
        />
        <div className={styles.reloadRow}>
          <button
            type="button"
            onClick={() => void handleReloadMetadata()}
            disabled={writebackRunning || reloadBusy}
            className={styles.secondaryButton}
          >
            {reloadBusy ? '正在加载元数据...' : '在 Capture One 中加载元数据'}
          </button>
          <span className={styles.reloadHint}>先在 Capture One 中 Load Metadata，再返回 Gather 确认同步</span>
        </div>
      </>}
    </div>
  )
}
