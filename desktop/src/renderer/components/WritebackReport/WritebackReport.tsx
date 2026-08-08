import React from 'react'
import type { WritebackResult, WritebackItem } from '@gather/shared'
import { useTranslation } from '../../locales'
import { translateErrorCode } from '../../utils/errors'
import styles from './WritebackReport.module.css'

interface WritebackReportProps {
  result: WritebackResult | null
  failedItems: WritebackItem[]
  onRetryFailed: () => void
  onConfirmSync: () => void
  onCleanup?: () => void
  disabled?: boolean
  /** 状态机门控（2.3.5 P1）：false 时按钮保留但禁用，附禁用提示。 */
  canConfirmSync?: boolean
  canCleanup?: boolean
  confirmHint?: string
  cleanupHint?: string
}

export default function WritebackReport({
  result,
  failedItems,
  onRetryFailed,
  onConfirmSync,
  onCleanup,
  disabled = false,
  canConfirmSync = true,
  canCleanup = true,
  confirmHint,
  cleanupHint,
}: WritebackReportProps) {
  const { t } = useTranslation()
  const hasFailed = failedItems.length > 0
  const hasResult = result !== null

  return (
    <div className={styles.container}>
      {hasResult && (
        <div className={styles.summary}>
          <div className={`${styles.stat} ${styles.written}`}>
            <span className={styles.statValue}>{result!.written}</span>
            <span className={styles.statLabel}>{t('writeback.written')}</span>
          </div>
          <div className={`${styles.stat} ${styles.failed}`}>
            <span className={styles.statValue}>{result!.failed}</span>
            <span className={styles.statLabel}>{t('writeback.failed')}</span>
          </div>
          <div className={`${styles.stat} ${styles.skipped}`}>
            <span className={styles.statValue}>{result!.skipped}</span>
            <span className={styles.statLabel}>{t('writeback.skipped')}</span>
          </div>
        </div>
      )}

      {hasFailed && (
        <div className={styles.failedSection}>
          <h3 className={styles.failedTitle}>{t('writeback.failedItems', { count: failedItems.length })}</h3>
          <ul className={styles.failedList}>
            {failedItems.map((item) => (
              <li key={item.id ?? `${item.photoId}-${item.xmpPath}`} className={styles.failedItem}>
                <span className={styles.failedPath}>{item.photoPath || item.xmpPath}</span>
                {item.errorMessage && (
                  <span className={styles.failedError}>{translateErrorCode(item.errorMessage)}</span>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className={styles.actions}>
        {hasFailed && (
          <button className={styles.retryButton} onClick={onRetryFailed} disabled={disabled}>
            {t('writeback.retryFailed')}
          </button>
        )}
        <button
          className={styles.confirmButton}
          onClick={onConfirmSync}
          disabled={disabled || !canConfirmSync}
          title={confirmHint}
        >
          {t('writeback.confirmSync')}
        </button>
        {onCleanup && (
          <button
            className={styles.cleanupButton}
            onClick={onCleanup}
            disabled={disabled || !canCleanup}
            title={cleanupHint}
          >
            {t('writeback.cleanup')}
          </button>
        )}
      </div>
    </div>
  )
}
