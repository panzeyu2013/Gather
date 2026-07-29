import React, { Suspense, lazy, useEffect } from 'react'
import { HashRouter, Routes, Route, Navigate } from 'react-router-dom'
import PageShell from './components/Layout/PageShell'
import Loading from './components/Loading/Loading'
import ToastContainer from './components/Toast/ToastContainer'
import { useToastStore, type ToastType } from './components/Toast/ToastStore'

const Dashboard = lazy(() => import('./pages/Dashboard'))
const SessionDetail = lazy(() => import('./pages/SessionDetail'))
const Settings = lazy(() => import('./pages/Settings'))

export default function App() {
  const addToast = useToastStore((state) => state.addToast)

  useEffect(() => window.gather.onEvent('gather:notification', (data) => {
    const notification = data as { type?: unknown; message?: unknown }
    if (typeof notification.message !== 'string') return
    const allowedTypes: ToastType[] = ['info', 'success', 'warning', 'error']
    const type = allowedTypes.includes(notification.type as ToastType)
      ? notification.type as ToastType
      : 'info'
    addToast(type, notification.message)
  }), [addToast])

  return (
    <HashRouter>
      <Suspense fallback={<Loading />}>
        <Routes>
          <Route element={<PageShell />}>
            <Route path="/" element={<Dashboard />} />
            <Route path="/sessions/:sessionId/*" element={<SessionDetail />} />
            <Route path="/settings" element={<Settings />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Route>
        </Routes>
      </Suspense>
      <ToastContainer />
    </HashRouter>
  )
}
