import React, { Suspense, lazy } from 'react'
import { HashRouter, Routes, Route } from 'react-router-dom'
import PageShell from './components/Layout/PageShell'
import Loading from './components/Loading/Loading'
import ToastContainer from './components/Toast/ToastContainer'

const Dashboard = lazy(() => import('./pages/Dashboard'))
const Similarity = lazy(() => import('./pages/Similarity'))
const FaceKeywording = lazy(() => import('./pages/FaceKeywording'))

export default function App() {
  return (
    <HashRouter>
      <Suspense fallback={<Loading />}>
        <Routes>
          <Route element={<PageShell />}>
            <Route path="/" element={<Dashboard />} />
            <Route path="/similarity/:sessionId" element={<Similarity />} />
            <Route path="/face-kw/:sessionId" element={<FaceKeywording />} />
          </Route>
        </Routes>
      </Suspense>
      <ToastContainer />
    </HashRouter>
  )
}
