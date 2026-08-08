import React from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { jobsApi } from '../../api/jobs'
import styles from './Jobs.module.css'

const labels: Record<string, string> = {
  queued: '排队中', running: '运行中', cancelling: '取消中', succeeded: '已完成',
  failed: '失败', cancelled: '已取消', interrupted: '已中断',
}

export default function Jobs() {
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
        <div><p className={styles.eyebrow}>TASK CENTER</p><h1>任务中心</h1><p className={styles.muted}>持久化分析任务、进度和失败恢复。</p></div>
        <button
          disabled={action.isPending || !jobs.some(job => ['succeeded', 'cancelled'].includes(job.status))}
          onClick={() => action.mutate({ id: '', type: 'clear' })}
        >
          清理已完成
        </button>
      </header>
      <div className={styles.list}>
        {isLoading && <p className={styles.muted}>加载中…</p>}
        {jobs.map(job => {
          const progress = job.progressTotal > 0 ? Math.round(job.progressCurrent / job.progressTotal * 100) : 0
          return <article className={styles.row} key={job.id}>
            <div className={styles.identity}>
              <strong>{job.type}</strong>
              <span>{job.scopeId}</span>
              <small>尝试 {job.attemptCount} 次</small>
              {job.errorMessage && (
                <small className={styles.error} title={job.errorMessage}>
                  {job.errorCode ? `${job.errorCode}：` : ''}{job.errorMessage}
                </small>
              )}
            </div>
            <div className={styles.status}>{labels[job.status] ?? job.status}</div>
            <div className={styles.progress}><div style={{ width: `${progress}%` }} /><span>{progress}% {job.progressMessage}</span></div>
            <div className={styles.actions}>
              {['queued', 'running'].includes(job.status) && <button onClick={() => action.mutate({ id: job.id, type: 'cancel' })}>取消</button>}
              {['failed', 'interrupted', 'cancelled'].includes(job.status) && <button onClick={() => action.mutate({ id: job.id, type: 'retry' })}>重试</button>}
            </div>
          </article>
        })}
        {!isLoading && jobs.length === 0 && <p className={styles.muted}>暂无后台任务</p>}
      </div>
    </div>
  )
}
