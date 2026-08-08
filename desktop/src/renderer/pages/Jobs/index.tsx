import React from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { jobsApi } from '../../api/jobs'
import { useTranslation, type TranslationKey } from '../../locales'
import { translateErrorCode } from '../../utils/errors'
import { translatePhase } from '../../utils/progress'
import styles from './Jobs.module.css'

const STATUS_LABEL_KEYS: Record<string, TranslationKey> = {
  queued: 'jobs.status.queued', running: 'jobs.status.running', cancelling: 'jobs.status.cancelling',
  succeeded: 'jobs.status.succeeded', failed: 'jobs.status.failed', cancelled: 'jobs.status.cancelled',
  interrupted: 'jobs.status.interrupted',
}

export default function Jobs() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const { data: jobs = [], isLoading } = useQuery({
    queryKey: ['jobs'], queryFn: () => jobsApi.list(),
    // Only poll while something is queued or running; idle lists don't re-fetch
    // every 2s and don't re-render the whole page on a timer.
    refetchInterval: (query) => (
      query.state.data?.some((job) => ['queued', 'running'].includes(job.status))
        ? 2_000
        : false
    ),
  })
  const action = useMutation({
    mutationFn: ({ id, type }: { id: string; type: 'cancel' | 'retry' | 'clear' }) => {
      if (type === 'clear') return jobsApi.clearCompleted().then(() => true)
      return type === 'cancel' ? jobsApi.cancel(id) : jobsApi.retry(id)
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['jobs'] }),
  })
  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <div><p className={styles.eyebrow}>{t('jobs.eyebrow')}</p><h1>{t('jobs.title')}</h1><p className={styles.muted}>{t('jobs.subtitle')}</p></div>
        <button
          disabled={action.isPending || !jobs.some(job => ['succeeded', 'cancelled'].includes(job.status))}
          onClick={() => action.mutate({ id: '', type: 'clear' })}
        >
          {t('jobs.clearCompleted')}
        </button>
      </header>
      <div className={styles.list}>
        {isLoading && <p className={styles.muted}>{t('jobs.loading')}</p>}
        {jobs.map(job => {
          const progress = job.progressTotal > 0 ? Math.round(job.progressCurrent / job.progressTotal * 100) : 0
          return <article className={styles.row} key={job.id}>
            <div className={styles.identity}>
              <strong>{job.type}</strong>
              <span>{job.scopeId}</span>
              <small>{t('jobs.attempts', { count: job.attemptCount })}</small>
              {job.errorMessage && (
                <small className={styles.error} title={job.errorMessage}>
                  {translateErrorCode(job.errorMessage)}
                </small>
              )}
            </div>
            <div className={styles.status}>{STATUS_LABEL_KEYS[job.status] ? t(STATUS_LABEL_KEYS[job.status]) : job.status}</div>
            <div className={styles.progress}><div style={{ width: `${progress}%` }} /><span>{progress}% {translatePhase(job.progressMessage)}</span></div>
            <div className={styles.actions}>
              {['queued', 'running'].includes(job.status) && <button onClick={() => action.mutate({ id: job.id, type: 'cancel' })}>{t('jobs.cancel')}</button>}
              {['failed', 'interrupted', 'cancelled'].includes(job.status) && <button onClick={() => action.mutate({ id: job.id, type: 'retry' })}>{t('jobs.retry')}</button>}
            </div>
          </article>
        })}
        {!isLoading && jobs.length === 0 && <p className={styles.muted}>{t('jobs.empty')}</p>}
      </div>
    </div>
  )
}
