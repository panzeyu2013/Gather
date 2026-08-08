import React, { useCallback, useEffect, useState } from 'react'
import type { C1Health } from '../../../preload'
import { captureOneApi, type C1SyncStateView } from '../../api/captureOne'
import { useSessionStore } from '../../stores/sessionStore'
import { useTranslation, type TranslationKey } from '../../locales'
import styles from './C1HealthPanel.module.css'

const POLL_INTERVAL_MS = 12_000

const CHECK_ITEMS: Array<{ key: keyof C1Health; labelKey: TranslationKey }> = [
  { key: 'reachable', labelKey: 'c1.health.check.reachable' },
  { key: 'appRunning', labelKey: 'c1.health.check.appRunning' },
  { key: 'documentOpen', labelKey: 'c1.health.check.documentOpen' },
  { key: 'automationAuthorized', labelKey: 'c1.health.check.automationAuthorized' },
]

const QUEUE_KEYS: Array<{ key: keyof C1SyncStateView['xmp']; labelKey: TranslationKey }> = [
  { key: 'pending', labelKey: 'c1.health.queuePending' },
  { key: 'writing', labelKey: 'c1.health.queueWriting' },
  { key: 'written', labelKey: 'c1.health.queueWritten' },
  { key: 'synced', labelKey: 'c1.health.queueSynced' },
  { key: 'failed', labelKey: 'c1.health.queueFailed' },
  { key: 'conflict', labelKey: 'c1.health.queueConflict' },
]

const formatTime = (iso: string): string =>
  new Intl.DateTimeFormat(undefined, {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).format(new Date(iso))

/** 设置 → Capture One 健康面板（design_improvements.md 2.3.5 P2）。
 * c1:health 四层预检 + 写回队列计数 + 最近一次命令耗时 + 最近同步时间。
 * 队列计数来自 `c1:sync-state`（会话级），无当前工作区时显示占位。 */
export default function C1HealthPanel() {
  const currentSessionId = useSessionStore((s) => s.currentSessionId)
  const { t } = useTranslation()
  const [health, setHealth] = useState<C1Health | null>(null)
  const [healthError, setHealthError] = useState(false)
  const [checking, setChecking] = useState(false)
  const [sync, setSync] = useState<C1SyncStateView | null>(null)
  const [syncError, setSyncError] = useState(false)

  const refreshSync = useCallback(() => {
    if (!currentSessionId) return
    captureOneApi.syncState(currentSessionId)
      .then((view) => {
        setSync(view)
        setSyncError(false)
      })
      .catch(() => {
        setSyncError(true)
      })
  }, [currentSessionId])

  const checkHealth = useCallback(async () => {
    setChecking(true)
    try {
      const result = await captureOneApi.health()
      setHealth(result)
      setHealthError(false)
    } catch {
      setHealthError(true)
    } finally {
      setChecking(false)
    }
  }, [])

  useEffect(() => {
    void checkHealth()
    refreshSync()
    const timer = setInterval(refreshSync, POLL_INTERVAL_MS)
    return () => clearInterval(timer)
  }, [checkHealth, refreshSync])

  return (
    <div className={styles.panel}>
      <div className={styles.subSectionLabel}>{t('c1.health.sectionConnection')}</div>
      <div className={styles.checkRow}>
        <span className={styles.settingLabel}>{t('c1.health.preflight')}</span>
        <button
          type="button"
          className={styles.checkBtn}
          onClick={() => void checkHealth()}
          disabled={checking}
        >
          {checking ? t('c1.health.checking') : t('c1.health.recheck')}
        </button>
      </div>
      <div className={styles.checkList} aria-live="polite">
        {healthError ? (
          <p className={styles.panelHint}>{t('c1.health.preflightFailed')}</p>
        ) : health ? (
          CHECK_ITEMS.map((item) => {
            const passed = health[item.key]
            return (
              <div key={item.key} className={styles.checkItem}>
                <span
                  className={`${styles.checkMark} ${passed ? styles.checkPass : styles.checkFail}`}
                  aria-hidden="true"
                >
                  {passed ? '✓' : '✗'}
                </span>
                <span>{t(item.labelKey)}</span>
              </div>
            )
          })
        ) : (
          <p className={styles.panelHint}>{t('c1.health.detecting')}</p>
        )}
      </div>

      <div className={styles.settingDivider} />
      <div className={styles.subSectionLabel}>{t('c1.health.queueTitle')}</div>
      {currentSessionId ? (
        syncError ? (
          <p className={styles.panelHint}>{t('c1.health.syncStateError')}</p>
        ) : sync ? (
          <div className={styles.queueGrid}>
            {QUEUE_KEYS.map((item) => (
              <div key={item.key} className={styles.queueCell}>
                <span className={styles.queueValue}>{sync.xmp[item.key]}</span>
                <span className={styles.queueLabel}>{t(item.labelKey)}</span>
              </div>
            ))}
          </div>
        ) : (
          <p className={styles.panelHint}>{t('c1.health.reading')}</p>
        )
      ) : (
        <p className={styles.panelHint}>{t('c1.health.noSession')}</p>
      )}

      <div className={styles.settingDivider} />
      <div className={styles.settingRow}>
        <div className={styles.settingInfo}>
          <p className={styles.settingLabel}>{t('c1.health.latencyLabel')}</p>
          <p className={styles.settingDesc}>{t('c1.health.latencyDesc')}</p>
        </div>
        <div className={styles.settingValue}>
          {healthError || !health ? '—' : `${health.latencyMs} ms`}
        </div>
      </div>
      <div className={styles.settingRow}>
        <div className={styles.settingInfo}>
          <p className={styles.settingLabel}>{t('c1.health.lastSyncLabel')}</p>
          <p className={styles.settingDesc}>{t('c1.health.lastSyncDesc')}</p>
        </div>
        <div className={styles.settingValue}>
          {sync?.reloadAckedAt ? formatTime(sync.reloadAckedAt) : '—'}
        </div>
      </div>
    </div>
  )
}
