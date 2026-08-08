import React, { useCallback, Fragment } from 'react'
import { useParams, useNavigate, Link } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { sessionApi } from '../../../api/session'
import { jobsApi } from '../../../api/jobs'
import { indexerApi } from '../../../api/indexer'
import { useWorkspaceStatus } from '../../../hooks/useWorkspaceStatus'
import { useToastStore } from '../../../components/Toast/ToastStore'
import { useTranslation, type TranslationKey } from '../../../locales'
import { translateError } from '../../../utils/errors'
import {
  deriveInboxItems,
  deriveRecommendedNextView,
  deriveStageMarks,
  deriveWorkspaceHeaderCopy,
  type InboxItem,
} from './workspace-view'
import styles from './ControlCenter.module.css'

const TOOLS: Array<{ to: string; labelKey: TranslationKey }> = [
  { to: 'gallery', labelKey: 'workspace.gallery' },
  { to: 'similarity', labelKey: 'workspace.similarity' },
  { to: 'face-kw', labelKey: 'workspace.face' },
  { to: 'duplicates', labelKey: 'workspace.duplicate' },
  { to: 'culling', labelKey: 'workspace.culling' },
  { to: 'export', labelKey: 'workspace.export' },
]

export default function ControlCenter() {
  const { sessionId = '' } = useParams<{ sessionId: string }>()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const addToast = useToastStore((s) => s.addToast)
  const { t } = useTranslation()

  const { data: session } = useQuery({
    queryKey: ['session', sessionId],
    queryFn: () => sessionApi.get(sessionId),
    enabled: Boolean(sessionId),
  })
  const { data: status } = useWorkspaceStatus(sessionId)

  const retryJob = useCallback(async (jobId: string) => {
    try {
      await jobsApi.retry(jobId)
      addToast('info', t('controlCenter.jobRequeued'))
      queryClient.invalidateQueries({ queryKey: ['workspace-status', sessionId] })
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    } catch (error) {
      addToast('error', error instanceof Error ? translateError(error) : t('controlCenter.retryJobFailed'))
    }
  }, [sessionId, queryClient, addToast, t])

  // 索引失败重试：重新入队 metadata.scan（dedupeKey 复用终态行），状态由
  // workspace-status 的 indexing.status 从 'failed' 翻回 'active' 反映。
  const retryIndex = useCallback(async () => {
    try {
      await indexerApi.scan(sessionId)
      queryClient.invalidateQueries({ queryKey: ['workspace-status', sessionId] })
    } catch (error) {
      addToast('error', error instanceof Error ? translateError(error) : t('controlCenter.retryJobFailed'))
    }
  }, [sessionId, queryClient, addToast, t])

  const handleAction = (action: InboxItem['action']) => {
    if (action.type === 'navigate') {
      navigate(action.to)
    } else if (action.type === 'retry-job') {
      void retryJob(action.jobId)
    } else {
      const bar = document.getElementById('control-center-stages')
      bar?.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }
  }

  if (!status) return null

  const headerCopy = deriveWorkspaceHeaderCopy(
    status,
    session?.photoCount ?? 0,
    session?.truncatedImport ?? false,
    t,
  )
  const marks = deriveStageMarks(status.stage, t)
  const inboxItems = deriveInboxItems(status, session?.truncatedImport ?? false, t)
  const nextView = deriveRecommendedNextView(status.recommendedNext, status.staleAnalyses, sessionId, t)

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <h2 className={styles.workspaceName}>{session?.name ?? t('session.header.loading')}</h2>
        <p className={styles.workspaceMeta}>
          <span className={styles.photoCount}>{headerCopy.countText}</span>
          {headerCopy.percent !== null && (
            <span className={styles.indexPercent}>{t('controlCenter.indexedPercent', { percent: headerCopy.percent })}</span>
          )}
          {headerCopy.kind === 'error' && (
            <button
              type="button"
              className={styles.inboxAction}
              onClick={() => void retryIndex()}
            >
              {t('jobs.retry')}
            </button>
          )}
        </p>
      </header>

      <section className={styles.card} id="control-center-stages">
        <h3 className={styles.cardTitle}>{t('controlCenter.stageTitle')}</h3>
        <div className={styles.stageBar}>
          {marks.map((mark, i) => (
            <Fragment key={mark.id}>
              {i > 0 && (
                <span
                  className={`${styles.stageConnector} ${mark.reached ? styles.stageConnectorDone : ''}`}
                />
              )}
              <div
                className={`${styles.stageMark} ${
                  mark.reached ? styles.stageReached : ''
                } ${mark.current ? styles.stageCurrent : ''}`}
              >
                <span className={styles.stageDot} />
                <span className={styles.stageLabel}>{mark.label}</span>
              </div>
            </Fragment>
          ))}
        </div>
        <div className={styles.softFlags}>
          {status.softFlags.culled && <span className={styles.softFlag}>{t('workspace.stage.culled')}</span>}
          {status.softFlags.exported && <span className={styles.softFlag}>{t('workspace.stage.exported')}</span>}
        </div>
      </section>

      <section className={styles.card}>
        <h3 className={styles.cardTitle}>
          {t('controlCenter.inboxTitle')}
          <span className={styles.cardHint}>{t('controlCenter.inboxHint')}</span>
        </h3>
        {inboxItems.length === 0 ? (
          <div className={styles.inboxEmpty}>
            <span className={styles.inboxEmptyIcon} aria-hidden="true">✓</span>
            {t('controlCenter.inboxEmpty')}
          </div>
        ) : (
          <ul className={styles.inboxList}>
            {inboxItems.map((item, i) => (
              <li key={`${item.kind}-${i}`} className={styles.inboxItem}>
                <span className={styles.inboxLabel}>{item.label}</span>
                <button
                  type="button"
                  className={styles.inboxAction}
                  onClick={() => handleAction(item.action)}
                >
                  {item.actionLabel}
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className={styles.card}>
        <h3 className={styles.cardTitle}>{t('controlCenter.recommendedTitle')}</h3>
        <div className={`${styles.recommended} ${nextView.action ? '' : styles.recommendedDone}`}>
          <div className={styles.recommendedInfo}>
            <p className={styles.recommendedTitle}>{nextView.title}</p>
            <p className={styles.recommendedDetail}>{nextView.detail}</p>
          </div>
          {nextView.action && (
            <button
              type="button"
              className={styles.recommendedBtn}
              onClick={() => handleAction(nextView.action!)}
            >
              {nextView.actionLabel}
            </button>
          )}
        </div>
      </section>

      <section className={styles.card}>
        <h3 className={styles.cardTitle}>{t('controlCenter.toolboxTitle')}</h3>
        <div className={styles.toolbox}>
          {TOOLS.map((tool) => (
            <Link
              key={tool.to}
              to={`/sessions/${sessionId}/${tool.to}`}
              className={styles.toolChip}
            >
              {t(tool.labelKey)}
            </Link>
          ))}
        </div>
      </section>
    </div>
  )
}
