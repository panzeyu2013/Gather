import React, { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { jobsApi } from '../../api/jobs'
import { useTranslation, type TranslationKey } from '../../locales'
import { translateJobErrorMessage } from '../../utils/errors'
import { translatePhase } from '../../utils/progress'
import { isAnalysisJobClearable } from '../../utils/jobs'
import styles from './Jobs.module.css'
import { JobsIcon } from '../../components/Layout/Sidebar'

const STATUS_LABEL_KEYS: Record<string, TranslationKey> = {
  queued: 'jobs.status.queued', running: 'jobs.status.running', cancelling: 'jobs.status.cancelling',
  succeeded: 'jobs.status.succeeded', failed: 'jobs.status.failed', cancelled: 'jobs.status.cancelled',
  interrupted: 'jobs.status.interrupted',
}

const JOB_TYPE_KEYS: Record<string, TranslationKey> = {
  'metadata.scan': 'jobs.type.metadataScan',
  'checksum.backfill': 'jobs.type.checksumBackfill',
  'similarity.analyze': 'jobs.type.similarityAnalyze',
  'face.analyze': 'jobs.type.faceAnalyze',
  'duplicate.scan': 'jobs.type.duplicateScan',
  'quality.score': 'jobs.type.qualityScore',
  'export.execute': 'jobs.type.exportExecute',
  'thumbnail.build': 'jobs.type.thumbnailBuild',
}

export default function Jobs() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [showHistory, setShowHistory] = useState(false)
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
  const attentionJobs = jobs.filter(job => job.status !== 'succeeded')
  const historyJobs = jobs.filter(job => job.status === 'succeeded')

  const renderJob = (job: typeof jobs[number], compact = false) => {
    const progress = job.progressTotal > 0 ? Math.round(job.progressCurrent / job.progressTotal * 100) : 0
    return <article className={`${styles.row} ${compact ? styles.rowCompact : ''}`} key={job.id}>
      <div className={styles.identity}>
        <strong>{JOB_TYPE_KEYS[job.type] ? t(JOB_TYPE_KEYS[job.type]) : job.type}</strong>
        <span title={job.scopeId}>{t('jobs.workspaceScope', { id: job.scopeId.slice(0, 8) })}</span>
        {!compact && <small>{t('jobs.attempts', { count: job.attemptCount })}</small>}
        {job.errorMessage && (
          <small className={styles.error} title={job.errorMessage}>
            {translateJobErrorMessage(job.errorMessage, t)}
          </small>
        )}
      </div>
      <div className={styles.status}>{STATUS_LABEL_KEYS[job.status] ? t(STATUS_LABEL_KEYS[job.status]) : job.status}</div>
      {!compact && <div className={styles.progress}><div style={{ width: `${progress}%` }} /><span>{progress}% {translatePhase(job.progressMessage)}</span></div>}
      {!compact && <div className={styles.actions}>
        {['queued', 'running'].includes(job.status) && <button onClick={() => action.mutate({ id: job.id, type: 'cancel' })}>{t('jobs.cancel')}</button>}
        {['failed', 'interrupted', 'cancelled'].includes(job.status) && <button onClick={() => action.mutate({ id: job.id, type: 'retry' })}>{t('jobs.retry')}</button>}
      </div>}
    </article>
  }

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <div><p className={styles.eyebrow}>{t('jobs.eyebrow')}</p><h1>{t('jobs.title')}</h1><p className={styles.muted}>{t('jobs.subtitle')}</p></div>
        <button
          disabled={action.isPending || !jobs.some(isAnalysisJobClearable)}
          onClick={() => action.mutate({ id: '', type: 'clear' })}
        >
          {t('jobs.clearCompleted')}
        </button>
      </header>
      {isLoading ? (
        <div className={styles.empty}><p className={styles.muted}>{t('jobs.loading')}</p></div>
      ) : jobs.length === 0 ? (
        <div className={styles.empty}>
          <span className={styles.emptyIcon} aria-hidden="true"><JobsIcon /></span>
          <p>{t('jobs.empty')}</p>
        </div>
      ) : (
      <div className={styles.jobSections}>
        <section>
          <h2 className={styles.sectionTitle}>{t('jobs.attentionTitle')}</h2>
          {attentionJobs.length > 0
            ? <div className={styles.list}>{attentionJobs.map(job => renderJob(job))}</div>
            : <div className={styles.quietState}>{t('jobs.noAttention')}</div>}
        </section>
        {historyJobs.length > 0 && (
          <section>
            <button
              type="button"
              className={styles.historyToggle}
              aria-expanded={showHistory}
              onClick={() => setShowHistory(value => !value)}
            >
              <span>{t('jobs.historyTitle')}</span>
              <span>{showHistory ? t('jobs.hideHistory') : t('jobs.showHistory', { count: historyJobs.length })}</span>
            </button>
            {showHistory && <div className={styles.list}>{historyJobs.map(job => renderJob(job, true))}</div>}
          </section>
        )}
      </div>
      )}
    </div>
  )
}
