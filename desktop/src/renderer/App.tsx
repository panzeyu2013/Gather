import React, { Suspense, lazy } from 'react'
import { HashRouter, Routes, Route } from 'react-router-dom'
import PageShell from './components/Layout/PageShell'
import Loading from './components/Loading/Loading'
import ToastContainer from './components/Toast/ToastContainer'

const Dashboard = lazy(() => import('./pages/Dashboard'))
const SessionDetail = lazy(() => import('./pages/SessionDetail'))
const Settings = lazy(() => import('./pages/Settings'))
const Persons = lazy(() => import('./pages/Persons'))
const PersonDetail = lazy(() => import('./pages/Persons/PersonDetail'))

export default function App() {
  return (
    <HashRouter>
      <Suspense fallback={<Loading />}>
        <Routes>
          <Route element={<PageShell />}>
            <Route path="/" element={<Dashboard />} />
            <Route path="/sessions/:sessionId/*" element={<SessionDetail />} />
            <Route path="/persons" element={<Persons />} />
            <Route path="/persons/:personId" element={<PersonDetail />} />
            <Route path="/settings" element={<Settings />} />
          </Route>
        </Routes>
      </Suspense>
      <ToastContainer />
    </HashRouter>
  )
}
