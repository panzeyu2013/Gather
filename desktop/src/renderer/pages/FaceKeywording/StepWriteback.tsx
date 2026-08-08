import React, { useState, useMemo } from 'react'
import { useFaceKwStore } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'
import WritebackReport from '../../components/WritebackReport/WritebackReport'
import { useToastStore } from '../../components/Toast/ToastStore'
import type { WritebackResult, WritebackItem } from '@gather/shared'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from '../../locales'
import { translateError } from '../../utils/errors'
import styles from './StepWriteback.module.css'

export default function StepWriteback() {
  const { t } = useTranslation()
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
      setWritebackReport(sessionId, t('face.previewReport', { count: preview.totalCount, photos: preview.affectedPhotos }))
    } catch (e) {
      setWritebackReport(sessionId, t('face.previewFailed', { message: translateError(e) }))
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
      setWritebackReport(sessionId, t('face.writebackReport', { written: result.written, failed: result.failed, skipped: result.skipped }))
    } catch (e) {
      setWritebackReport(sessionId, t('face.writebackFailed', { message: translateError(e) }))
    } finally {
      setWritebackRunning(sessionId, false)
    }
  }

  const handleRetryFailed = async () => {
    if (!sessionId) return
    setWritebackRunning(sessionId, true)
    try {
      setWritebackReport(sessionId, t('face.retrying'))
      const failedOnly = failedItems
      const result = await faceKwApi.writeback(sessionId, failedOnly)
      setWritebackResult(result)
      if (result.failed === 0) setFailedItems([])
    } catch (e) {
      setWritebackReport(sessionId, t('face.retryFailed', { message: translateError(e) }))
    } finally {
      setWritebackRunning(sessionId, false)
    }
  }

  const handleConfirmSync = async () => {
    if (!sessionId) return
    try {
      await faceKwApi.confirmSync(sessionId)
      setSyncConfirmed(true)
      setWritebackReport(sessionId, t('face.syncConfirmed'))
    } catch (e) {
      setWritebackReport(sessionId, t('face.confirmFailed', { message: translateError(e) }))
    }
  }

  const handleCleanup = async () => {
    if (!sessionId) return
    try {
      const result = await faceKwApi.cleanup(sessionId)
      setWritebackReport(sessionId, t('face.cleanupDone', { count: result.deletedCount }))
    } catch (e) {
      setWritebackReport(sessionId, t('face.cleanupFailed', { message: translateError(e) }))
    }
  }

  const handleReloadMetadata = async () => {
    if (!sessionId) return
    setReloadBusy(true)
    try {
      await window.gather.reloadMetadata()
      setWritebackReport(sessionId, t('face.reloadDone'))
    } catch (e) {
      addToast('error', translateError(e) || t('face.loadMetadataFailed'))
    } finally {
      setReloadBusy(false)
    }
  }

  return (
    <div className={styles.page}>
      <h2 className={styles.title}>{t('face.writebackTitle')}</h2>

      <div className={styles.stats}>
        <div className={styles.statCard}>
          <div className={styles.statValueAccent}>{boundClusters.length}</div>
          <div className={styles.statLabel}>{t('face.boundClusters')}</div>
        </div>
        <div className={styles.statCard}>
          <div className={styles.statValue}>{totalAffected}</div>
          <div className={styles.statLabel}>{t('face.affectedPhotos')}</div>
        </div>
        <div className={styles.statCard}>
          <div className={styles.statValueWarning}>{unboundClusters.length}</div>
          <div className={styles.statLabel}>{t('face.unboundSkipped')}</div>
        </div>
      </div>

      <div className={styles.preview}>
        {boundClusters.map((c) => (
          <div key={c.id} className={styles.cluster}>
            <div className={styles.clusterTitle}>
              {c.binding!.roleName} ({t('face.clusterPhotoCount', { count: c.size })})
              <span className={styles.clusterKeywords}>
                {c.binding!.keywords.join(', ')}
              </span>
            </div>
            {c.members.slice(0, 5).map((m, idx) => (
              <div key={idx} className={styles.memberName}>{m.filename}</div>
            ))}
            {c.members.length > 5 && (
              <div className={styles.more}>{t('face.moreMembers', { count: c.members.length - 5 })}</div>
            )}
          </div>
        ))}
        {boundClusters.length === 0 && (
          <div className={styles.empty}>
            {t('face.noBoundClusters')}
          </div>
        )}
      </div>

      {previewItems.length > 0 && (
        <div className={styles.xmpPreview} aria-label={t('face.xmpPreviewLabel')}>
          {previewItems.slice(0, 50).map(item => (
            <div className={styles.xmpPreviewRow} key={item.xmpPath}>
              <strong title={item.xmpPath}>{item.xmpPath.split(/[/\\]/).pop()}</strong>
              <span>
                {(item.preview?.before.keywords ?? []).join('、') || t('face.noKeywords')}
                {' → '}
                {(item.preview?.after.keywords ?? item.keywords).join('、') || t('face.noKeywords')}
              </span>
              <small>
                {item.preview?.willCreate ? t('face.newXmp') : t('face.updateXmp')}
                {(item.preview?.sharedPhotoCount ?? 1) > 1
                  ? t('face.sharedCount', { count: item.preview?.sharedPhotoCount })
                  : ''}
                {item.preview?.externalChanged ? t('face.externalConflict') : ''}
                {t('face.source')}
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
          {t('face.preview')}
        </button>
        <button
          type="button"
          onClick={() => void handleExecute()}
          disabled={boundClusters.length === 0 || writebackRunning}
          className={styles.primaryButton}
        >
          {writebackRunning ? t('face.executing') : t('face.execute')}
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
            {reloadBusy ? t('face.reloading') : t('face.reloadBtn')}
          </button>
          <span className={styles.reloadHint}>{t('face.reloadHint')}</span>
        </div>
      </>}
    </div>
  )
}
