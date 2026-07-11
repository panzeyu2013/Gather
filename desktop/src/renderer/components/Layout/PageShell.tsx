import React from 'react'
import { Outlet } from 'react-router-dom'
import Sidebar from './Sidebar'
import ErrorBoundary from '../ErrorBoundary/ErrorBoundary'
import styles from './PageShell.module.css'

export default function PageShell() {
  return (
    <div className={styles.shell}>
      <Sidebar />
      <main className={styles.main}>
        <ErrorBoundary>
          <Outlet />
        </ErrorBoundary>
      </main>
    </div>
  )
}
