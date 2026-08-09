import React, { useLayoutEffect, useRef } from 'react'
import { Outlet, useLocation } from 'react-router-dom'
import Sidebar from './Sidebar'
import { RouteAwareErrorBoundary } from '../ErrorBoundary/ErrorBoundary'
import styles from './PageShell.module.css'

export default function PageShell() {
  const location = useLocation()
  const isSession = location.pathname.startsWith('/sessions/')
  const mainRef = useRef<HTMLElement>(null)

  useLayoutEffect(() => {
    if (!mainRef.current) return
    mainRef.current.scrollTop = 0
    mainRef.current.scrollLeft = 0
  }, [location.pathname])

  return (
    <div className={styles.shell}>
      <Sidebar />
      <main ref={mainRef} className={`${styles.main} ${isSession ? styles.sessionMain : ''}`}>
        <RouteAwareErrorBoundary>
          <Outlet />
        </RouteAwareErrorBoundary>
      </main>
    </div>
  )
}
