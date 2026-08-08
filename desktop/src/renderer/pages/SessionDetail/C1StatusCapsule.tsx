import React, { useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { captureOneApi, type C1SyncStateView } from '../../api/captureOne'
import { useEvent } from '../../hooks/useEvent'
import { useTranslation } from '../../locales'
import {
  c1QueueCount,
  deriveCapsuleView,
  type CapsuleTone,
} from './ControlCenter/workspace-view'
import styles from './C1StatusCapsule.module.css'

const POLL_INTERVAL_MS = 12_000

const formatTime = (iso: string): string =>
  new Intl.DateTimeFormat(undefined, {
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(iso))

const TONE_CLASS: Record<CapsuleTone, string> = {
  green: styles.dotGreen,
  yellow: styles.dotYellow,
  red: styles.dotRed,
  gray: styles.dotGray,
}

/** 工作区头部 C1 连接健康胶囊（design_improvements.md 2.3.5 P2）。
 * 每 12s 轮询 `c1:sync-state`；`culling:sync-status` 推送到达时即时刷新。
 * 点击跳转 设置 → Capture One 健康面板（Settings 无页签，面板常驻首屏）。 */
export default function C1StatusCapsule({ sessionId }: { sessionId?: string }) {
  const navigate = useNavigate()
  const { t } = useTranslation()
  const [sync, setSync] = useState<C1SyncStateView | null>(null)
  const [error, setError] = useState(false)

  const refresh = useCallback(() => {
    if (!sessionId) return
    captureOneApi.syncState(sessionId)
      .then((view) => {
        setSync(view)
        setError(false)
      })
      .catch(() => {
        setError(true)
      })
  }, [sessionId])

  useEffect(() => {
    refresh()
    const timer = setInterval(refresh, POLL_INTERVAL_MS)
    return () => clearInterval(timer)
  }, [refresh])

  useEvent('culling:sync-status', (payload) => {
    const data = payload as { sessionId?: string }
    if (data.sessionId === sessionId) refresh()
  }, Boolean(sessionId))

  const view = deriveCapsuleView(sync, error, t)
  const queue = c1QueueCount(sync)
  const reloadedAt = sync?.reloadAckedAt ?? null

  const titleParts = [
    view.detail,
    queue > 0 ? t('c1.capsule.queueTitle', { count: queue }) : null,
    reloadedAt ? t('c1.capsule.lastSyncAt', { time: formatTime(reloadedAt) }) : null,
  ].filter(Boolean)
  const title = titleParts.length > 0 ? titleParts.join('\n') : undefined

  return (
    <button
      type="button"
      className={styles.capsule}
      onClick={() => navigate('/settings')}
      title={title}
      aria-label={t('c1.capsule.ariaLabel')}
    >
      <span className={`${styles.dot} ${TONE_CLASS[view.tone]}`} />
      <span className={styles.label}>{view.label}</span>
      {queue > 0 && <span className={styles.queueCount}>{queue}</span>}
      {reloadedAt && <span className={styles.syncedAt}>{formatTime(reloadedAt)}</span>}
    </button>
  )
}
