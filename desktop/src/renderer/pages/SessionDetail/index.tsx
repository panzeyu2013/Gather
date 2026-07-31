import React, { Suspense, lazy, useEffect } from 'react'
import { Routes, Route, NavLink, useParams, Navigate, Link, useLocation } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import Loading from '../../components/Loading/Loading'
import { sessionApi } from '../../api/session'
import { indexerApi } from '../../api/indexer'
import { useSessionStore } from '../../stores/sessionStore'
import styles from './SessionDetail.module.css'

const Gallery = lazy(() => import('./Gallery'))
const Similarity = lazy(() => import('../../pages/Similarity'))
const FaceKeywording = lazy(() => import('../../pages/FaceKeywording'))
const Duplicates = lazy(() => import('./Duplicates'))
const Culling = lazy(() => import('./Culling'))
const Export = lazy(() => import('./Export'))

export default function SessionDetail() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const location = useLocation()
  const setSession = useSessionStore((state) => state.setSession)
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

  const isCulling = location.pathname.endsWith('/culling')

  return (
    <div className={styles.container}>
      <header className={`${styles.sessionHeader} ${isCulling ? styles.workbenchHeader : ''}`}>
        <div className={styles.sessionIdentity}>
          <Link to="/" className={styles.backLink} aria-label="返回工作台" title="返回工作台">←</Link>
          <div className={styles.sessionTitleGroup}>
            <span className={styles.eyebrow}>当前工作区</span>
            <h1 className={styles.sessionTitle}>{session?.name ?? '加载中…'}</h1>
          </div>
          <Link to="/settings" className={styles.sessionUtilityLink}>设置</Link>
        </div>
        <nav className={styles.tabs} aria-label="工作区功能">
          <NavLink end to={`/sessions/${sessionId}/gallery`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            浏览
          </NavLink>
          <NavLink end to={`/sessions/${sessionId}/similarity`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            相似度
          </NavLink>
          <NavLink end to={`/sessions/${sessionId}/face-kw`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            人脸
          </NavLink>
          <NavLink end to={`/sessions/${sessionId}/duplicates`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            重复
          </NavLink>
          <NavLink end to={`/sessions/${sessionId}/culling`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            挑片
          </NavLink>
          <NavLink end to={`/sessions/${sessionId}/export`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
            导出
          </NavLink>
        </nav>
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
            <Route index element={<Navigate to="gallery" replace />} />
          </Routes>
        </Suspense>
      </main>
    </div>
  )
}
