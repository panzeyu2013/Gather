import React, { Suspense, lazy, useEffect, useState } from 'react'
import { Routes, Route, NavLink, useParams, Link, useLocation } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import Loading from '../../components/Loading/Loading'
import { sessionApi } from '../../api/session'
import { jobsApi } from '../../api/jobs'
import { indexerApi } from '../../api/indexer'
import { useEvent } from '../../hooks/useEvent'
import { useSessionStore } from '../../stores/sessionStore'
import {
  deriveIndexHeaderCopy,
  TERMINAL_JOB_STATUSES,
  type IndexJobSnapshot,
} from './indexProgress'
import C1StatusCapsule from './C1StatusCapsule'
import { useTranslation } from '../../locales'
import styles from './SessionDetail.module.css'

const Gallery = lazy(() => import('./Gallery'))
const ControlCenter = lazy(() => import('./ControlCenter'))
const Similarity = lazy(() => import('../../pages/Similarity'))
const FaceKeywording = lazy(() => import('../../pages/FaceKeywording'))
const Duplicates = lazy(() => import('./Duplicates'))
const Culling = lazy(() => import('./Culling'))
const Export = lazy(() => import('./Export'))

export default function SessionDetail() {
  const { t } = useTranslation()
  const { sessionId } = useParams<{ sessionId: string }>()
  const location = useLocation()
  const setSession = useSessionStore((state) => state.setSession)
  const queryClient = useQueryClient()
  // Live snapshot of the workspace's background `metadata.scan` job (design
  // 3.3.4): progress frames while it runs, terminal status once it finishes.
  const [indexJob, setIndexJob] = useState<IndexJobSnapshot | null>(null)
  const { data: session } = useQuery({
    queryKey: ['session', sessionId],
    queryFn: () => sessionApi.get(sessionId!),
    enabled: Boolean(sessionId),
  })

  useEffect(() => {
    if (sessionId) setSession(sessionId)
  }, [sessionId, setSession])

  useEffect(() => {
    if (!sessionId || !session?.sourcePath) return
    void indexerApi.scan(sessionId).catch(error => {
      console.warn('Unable to schedule workspace index scan', error)
    })
  }, [session?.sourcePath, sessionId])

  // Seed from the persisted job table so a scan that finished before this
  // page mounted still leaves the header in the right state (exact count
  // after success, 索引失败 after failure); the jobs:progress subscription
  // below keeps the snapshot live afterwards.
  useEffect(() => {
    let disposed = false
    void jobsApi.list().then((jobs) => {
      if (disposed || !sessionId) return
      const scans = jobs
        .filter((job) => job.type === 'metadata.scan' && job.scopeId === sessionId)
        .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1))
      const latest = scans[0]
      if (latest) {
        setIndexJob({
          status: latest.status,
          current: latest.progressCurrent,
          total: latest.progressTotal,
        })
      }
    }).catch(() => undefined)
    return () => { disposed = true }
  }, [sessionId])

  useEvent('jobs:progress', (payload) => {
    const data = payload as {
      jobType?: string
      scopeId?: string
      current?: number
      total?: number
      status?: string
    }
    if (data.jobType !== 'metadata.scan' || data.scopeId !== sessionId) return
    const terminal = data.status && TERMINAL_JOB_STATUSES.includes(data.status)
    if (terminal) {
      setIndexJob({ status: data.status, current: data.current ?? 0, total: data.total ?? 0 })
      // A finished scan backfills photo_count; refresh the session query so
      // the header flips from progress to the exact count.
      if (data.status === 'succeeded') {
        queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
      }
    } else {
      setIndexJob({ status: undefined, current: data.current ?? 0, total: data.total ?? 0 })
    }
  })

  const handleRetryIndex = () => {
    if (!sessionId) return
    setIndexJob({ status: 'queued', current: 0, total: 0 })
    void indexerApi.scan(sessionId).catch((error) => {
      console.warn('Unable to schedule workspace index scan', error)
      setIndexJob({ status: 'failed', current: 0, total: 0 })
    })
  }

  const indexCopy = session
    ? deriveIndexHeaderCopy(indexJob, {
        photoCount: session.photoCount,
        truncatedImport: session.truncatedImport,
      })
    : null

  const isCulling = location.pathname.endsWith('/culling')

  return (
    <div className={styles.container}>
      <header className={`${styles.sessionHeader} ${isCulling ? styles.workbenchHeader : ''}`}>
        <div className={styles.sessionIdentity}>
          <Link to="/" className={styles.backLink} aria-label={t('session.header.back')} title={t('session.header.back')}>←</Link>
          <div className={styles.sessionTitleGroup}>
            <span className={styles.eyebrow}>{t('session.header.eyebrow')}</span>
            <h1 className={styles.sessionTitle}>{session?.name ?? t('session.header.loading')}</h1>
          </div>
          <Link to="/settings" className={styles.sessionUtilityLink}>{t('session.header.settings')}</Link>
          <C1StatusCapsule sessionId={sessionId} />
        </div>
        <nav className={styles.tabs} aria-label={t('session.header.navLabel')}>
          <NavLink end to={`/sessions/${sessionId}/gallery`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            {t('workspace.gallery')}
          </NavLink>
          <NavLink end to={`/sessions/${sessionId}/similarity`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            {t('workspace.similarity')}
          </NavLink>
          <NavLink end to={`/sessions/${sessionId}/face-kw`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            {t('workspace.face')}
          </NavLink>
          <NavLink end to={`/sessions/${sessionId}/duplicates`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            {t('workspace.duplicate')}
          </NavLink>
          <NavLink end to={`/sessions/${sessionId}/culling`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            {t('workspace.culling')}
          </NavLink>
          <NavLink end to={`/sessions/${sessionId}/export`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            {t('workspace.export')}
          </NavLink>
        </nav>
        {indexCopy && (
          <div className={styles.indexProgress}>
            {indexCopy.kind === 'scanning' && (
              <>
                <span className={styles.indexProgressLabel}>{indexCopy.text}</span>
                {indexCopy.percent !== null && (
                  <span
                    className={styles.indexProgressBar}
                    role="progressbar"
                    aria-valuenow={indexCopy.percent}
                    aria-valuemin={0}
                    aria-valuemax={100}
                  >
                    <span
                      className={styles.indexProgressBarFill}
                      style={{ width: `${indexCopy.percent}%` }}
                    />
                  </span>
                )}
              </>
            )}
            {indexCopy.kind === 'error' && (
              <button type="button" className={styles.indexProgressError} onClick={handleRetryIndex}>
                {t('session.header.indexError', { text: indexCopy.text })}
              </button>
            )}
            {indexCopy.kind === 'count' && (
              <span className={styles.indexProgressLabel}>{indexCopy.text}</span>
            )}
          </div>
        )}
      </header>
      <main className={`${styles.content} ${
        isCulling ? styles.cullingContent : ''
      }`}>
        <Suspense fallback={<Loading />}>
          <Routes>
            <Route path="gallery" element={<Gallery />} />
            <Route path="similarity" element={<Similarity />} />
            <Route path="face-kw" element={<FaceKeywording />} />
            <Route path="duplicates" element={<Duplicates />} />
            <Route path="culling" element={<Culling />} />
            <Route path="export" element={<Export />} />
            <Route index element={<ControlCenter />} />
          </Routes>
        </Suspense>
      </main>
    </div>
  )
}
