import React from 'react'
import type { WritebackResult, WritebackItem } from '@gather/shared'
import styles from './WritebackReport.module.css'

interface WritebackReportProps {
  result: WritebackResult | null
  failedItems: WritebackItem[]
  onRetryFailed: () => void
  onConfirmSync: () => void
  onCleanup: () => void
}

export default function WritebackReport({
  result,
  failedItems,
  onRetryFailed,
  onConfirmSync,
  onCleanup,
}: WritebackReportProps) {
  const hasFailed = failedItems.length > 0
  const hasResult = result !== null

  return (
    <div className={styles.container}>
      {hasResult && (
        <div className={styles.summary}>
          <div className={`${styles.stat} ${styles.written}`}>
            <span className={styles.statValue}>{result!.written}</span>
            <span className={styles.statLabel}>已写入</span>
          </div>
          <div className={`${styles.stat} ${styles.failed}`}>
            <span className={styles.statValue}>{result!.failed}</span>
            <span className={styles.statLabel}>失败</span>
          </div>
          <div className={`${styles.stat} ${styles.skipped}`}>
            <span className={styles.statValue}>{result!.skipped}</span>
            <span className={styles.statLabel}>已跳过</span>
          </div>
        </div>
      )}

      {hasFailed && (
        <div className={styles.failedSection}>
          <h3 className={styles.failedTitle}>失败项 ({failedItems.length})</h3>
          <ul className={styles.failedList}>
            {failedItems.map((item) => (
              <li key={item.id ?? `${item.photoId}-${item.xmpPath}`} className={styles.failedItem}>
                <span className={styles.failedPath}>{item.photoPath || item.xmpPath}</span>
                {item.errorMessage && (
                  <span className={styles.failedError}>{item.errorMessage}</span>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className={styles.actions}>
        {hasFailed && (
          <button className={styles.retryButton} onClick={onRetryFailed}>
            重试失败项
          </button>
        )}
        <button className={styles.confirmButton} onClick={onConfirmSync}>
          确认同步
        </button>
        <button className={styles.cleanupButton} onClick={onCleanup}>
          清理
        </button>
      </div>
    </div>
  )
}
