import React, { Suspense, lazy } from 'react'
import { Routes, Route, NavLink, useParams, Navigate } from 'react-router-dom'
import Loading from '../../components/Loading/Loading'
import styles from './SessionDetail.module.css'

const Gallery = lazy(() => import('./Gallery'))
const Similarity = lazy(() => import('../../pages/Similarity'))
const FaceKeywording = lazy(() => import('../../pages/FaceKeywording'))
const Duplicates = lazy(() => import('./Duplicates'))
const Culling = lazy(() => import('./Culling'))
const Export = lazy(() => import('./Export'))
const History = lazy(() => import('./History'))

export default function SessionDetail() {
  const { sessionId } = useParams<{ sessionId: string }>()

  return (
    <div className={styles.container}>
      <nav className={styles.tabs}>
        <NavLink to={`/sessions/${sessionId}/gallery`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
          浏览
        </NavLink>
        <NavLink to={`/sessions/${sessionId}/similarity`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
          相似度
        </NavLink>
        <NavLink to={`/sessions/${sessionId}/face-kw`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
          人脸
        </NavLink>
        <NavLink to={`/sessions/${sessionId}/duplicates`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
          重复
        </NavLink>
        <NavLink to={`/sessions/${sessionId}/culling`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
          筛选
        </NavLink>
        <NavLink to={`/sessions/${sessionId}/export`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
          导出
        </NavLink>
        <NavLink to={`/sessions/${sessionId}/history`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
          历史
        </NavLink>
        <NavLink to={`/sessions/${sessionId}/writeback`} className={({ isActive }) => isActive ? styles.tabActive : styles.tab}>
          写回
        </NavLink>
      </nav>
      <main className={styles.content}>
        <Suspense fallback={<Loading />}>
          <Routes>
            <Route path="gallery" element={<Gallery />} />
            <Route path="similarity" element={<Similarity />} />
            <Route path="face-kw" element={<FaceKeywording />} />
            <Route path="duplicates" element={<Duplicates />} />
            <Route path="culling" element={<Culling />} />
            <Route path="export" element={<Export />} />
            <Route path="history" element={<History />} />
            <Route path="writeback" element={<div className={styles.placeholder}>写回功能即将上线</div>} />
            <Route index element={<Navigate to="gallery" replace />} />
          </Routes>
        </Suspense>
      </main>
    </div>
  )
}
