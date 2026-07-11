import React from 'react'
import { Outlet } from 'react-router-dom'
import Sidebar from './Sidebar'
import styles from './PageShell.module.css'

export default function PageShell() {
  return (
    <div className={styles.shell}>
      <Sidebar />
      <main className={styles.main}>
        <Outlet />
      </main>
    </div>
  )
}
