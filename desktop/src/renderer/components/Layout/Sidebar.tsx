import React from 'react'
import { NavLink, useLocation } from 'react-router-dom'
import { useSessionStore } from '../../stores/sessionStore'
import styles from './Sidebar.module.css'

function HomeIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M4 10.5 12 4l8 6.5V20a1 1 0 0 1-1 1h-5v-6h-4v6H5a1 1 0 0 1-1-1z" />
    </svg>
  )
}

function SessionIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <rect x="3" y="5" width="18" height="14" rx="2" />
      <path d="m7 15 3-3 2.2 2.2L15.5 11l2.5 4M8 9h.01" />
    </svg>
  )
}

function SettingsIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.83 2.83-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56V21h-4v-.08A1.7 1.7 0 0 0 8.94 19.4a1.7 1.7 0 0 0-1.88.34l-.06.06-2.83-2.83.06-.06A1.7 1.7 0 0 0 4.6 15 1.7 1.7 0 0 0 3.08 14H3v-4h.08A1.7 1.7 0 0 0 4.6 9a1.7 1.7 0 0 0-.34-1.88L4.2 7.06 7.03 4.2l.06.06A1.7 1.7 0 0 0 9 4.6 1.7 1.7 0 0 0 10 3.08V3h4v.08A1.7 1.7 0 0 0 15 4.6a1.7 1.7 0 0 0 1.88-.34l.06-.06 2.83 2.83-.06.06A1.7 1.7 0 0 0 19.4 9 1.7 1.7 0 0 0 20.92 10H21v4h-.08A1.7 1.7 0 0 0 19.4 15Z" />
    </svg>
  )
}

export default function Sidebar() {
  const location = useLocation()
  const sessionId = useSessionStore((s) => s.currentSessionId)
  if (location.pathname.startsWith('/sessions/')) return null

  return (
    <nav className={styles.sidebar} aria-label="主导航">
      <NavLink to="/" end className={styles.brand} aria-label="Gather 工作台">
        <span className={styles.brandMark}>G</span>
        <span className={styles.brandName}>Gather</span>
      </NavLink>
      <ul className={styles.nav}>
        <li className={styles.navItem}>
          <NavLink to="/" end className={({ isActive }) => isActive ? styles.active : styles.navLink}>
            <HomeIcon />
            <span>工作台</span>
          </NavLink>
        </li>
        {sessionId && (
          <li className={styles.navItem}>
            <NavLink to={`/sessions/${sessionId}/gallery`} className={({ isActive }) => isActive ? styles.active : styles.navLink}>
              <SessionIcon />
              <span>当前会话</span>
            </NavLink>
          </li>
        )}
      </ul>
      <div className={styles.bottomNav}>
        <NavLink to="/settings" className={({ isActive }) => isActive ? styles.active : styles.navLink}>
          <SettingsIcon />
          <span>设置</span>
        </NavLink>
      </div>
    </nav>
  )
}
