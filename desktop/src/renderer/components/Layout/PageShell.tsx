import React from 'react'
import { Outlet, useLocation } from 'react-router-dom'
import Sidebar from './Sidebar'
import { RouteAwareErrorBoundary } from '../ErrorBoundary/ErrorBoundary'
import styles from './PageShell.module.css'

export default function PageShell() {
  const location = useLocation()
  const isSession = location.pathname.startsWith('/sessions/')

  return (
    <div className={styles.shell}>
      <Sidebar />
      <main className={`${styles.main} ${isSession ? styles.sessionMain : ''}`}>
        <RouteAwareErrorBoundary>
          <Outlet />
        </RouteAwareErrorBoundary>
      </main>
    </div>
  )
}
