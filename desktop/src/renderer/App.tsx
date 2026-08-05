import React, { Suspense, lazy, useEffect } from 'react'
import { HashRouter, Routes, Route, Navigate, useNavigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import PageShell from './components/Layout/PageShell'
import Loading from './components/Loading/Loading'
import ToastContainer from './components/Toast/ToastContainer'
import { useToastStore, type ToastType } from './components/Toast/ToastStore'
import { useEvent } from './hooks/useEvent'
import { sessionApi } from './api/session'
import { useSessionStore } from './stores/sessionStore'
import {
  getCommonParentPath,
  getPathBasename,
  importFailureMessage,
} from './utils/session-paths'

const Dashboard = lazy(() => import('./pages/Dashboard'))
const SessionDetail = lazy(() => import('./pages/SessionDetail'))
const Settings = lazy(() => import('./pages/Settings'))
const Library = lazy(() => import('./pages/Library'))
const Jobs = lazy(() => import('./pages/Jobs'))
const Persons = lazy(() => import('./pages/Persons'))
const PersonDetail = lazy(() => import('./pages/Persons/PersonDetail'))

function CaptureOneImportListener() {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const setSession = useSessionStore(state => state.setSession)
  const addToast = useToastStore(state => state.addToast)

  useEvent('c1:plugin-import', async data => {
    const files = (data as { files?: unknown }).files
    if (!Array.isArray(files) || !files.every(file => typeof file === 'string')) return
    const now = new Date()
    const sourcePath = getCommonParentPath(files)
    const name = getPathBasename(sourcePath) ||
      `C1 导入 ${now.getMonth() + 1}/${now.getDate()} ${now.getHours()}:${String(now.getMinutes()).padStart(2, '0')}`
    try {
      const session = await sessionApi.create(name, 'capture-one', files, sourcePath)
      void queryClient.invalidateQueries({ queryKey: ['sessions'] })
      if (session.failedFiles.length > 0) {
        addToast(
          'warning',
          importFailureMessage(session.added, session.failedFiles, 'Capture One 文件'),
        )
      }
      setSession(session.id)
      navigate(`/sessions/${session.id}/gallery`)
    } catch (error) {
      console.error('Plugin import failed:', error)
      addToast(
        'error',
        error instanceof Error ? error.message : 'Capture One 照片导入失败',
      )
    }
  })

  // Signal readiness only after the global import listener is mounted. This
  // lets the main process safely flush cold-start deep links without racing
  // React initialization.
  useEffect(() => {
    void window.gather.rendererReady()
  }, [])

  return null
}

export default function App() {
  const addToast = useToastStore((state) => state.addToast)

  useEvent('gather:notification', (data) => {
    const notification = data as { type?: unknown; message?: unknown }
    if (typeof notification.message !== 'string') return
    const allowedTypes: ToastType[] = ['info', 'success', 'warning', 'error']
    const type = allowedTypes.includes(notification.type as ToastType)
      ? notification.type as ToastType
      : 'info'
    addToast(type, notification.message)
  })

  return (
    <HashRouter>
      <CaptureOneImportListener />
      <Suspense fallback={<Loading />}>
        <Routes>
          <Route element={<PageShell />}>
            <Route path="/" element={<Dashboard />} />
            <Route path="/sessions/:sessionId/*" element={<SessionDetail />} />
            <Route path="/settings" element={<Settings />} />
            <Route path="/library" element={<Library />} />
            <Route path="/jobs" element={<Jobs />} />
            <Route path="/persons" element={<Persons />} />
            <Route path="/persons/:personId" element={<PersonDetail />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        </Routes>
      </Suspense>
      <ToastContainer />
    </HashRouter>
  )
}
