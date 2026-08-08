import React from 'react'
import { NavLink, useLocation } from 'react-router-dom'
import { useSessionStore } from '../../stores/sessionStore'
import { useTranslation } from '../../locales'
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

function LibraryIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <path d="M3 9h18M8 4v16" />
    </svg>
  )
}

function JobsIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5l3 2" />
    </svg>
  )
}

function PersonsIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="9" cy="8" r="3.5" />
      <path d="M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6" />
      <circle cx="17" cy="9" r="2.5" />
      <path d="M15.5 14.2c2.6.4 4.5 2.6 4.5 5.3" />
    </svg>
  )
}

export default function Sidebar() {
  const { t } = useTranslation()
  const location = useLocation()
  const sessionId = useSessionStore((s) => s.currentSessionId)
  if (location.pathname.startsWith('/sessions/')) return null

  return (
    <nav className={styles.sidebar} aria-label={t('nav.mainNav')}>
      <NavLink to="/" end className={styles.brand} aria-label={t('nav.brandLabel')}>
        <span className={styles.brandMark}>G</span>
        <span className={styles.brandName}>Gather</span>
      </NavLink>
      <ul className={styles.nav}>
        <li className={styles.navItem}>
          <NavLink to="/" end className={({ isActive }) => isActive ? styles.active : styles.navLink}>
            <HomeIcon />
            <span>{t('nav.home')}</span>
          </NavLink>
        </li>
        {sessionId && (
          <li className={styles.navItem}>
            <NavLink to={`/sessions/${sessionId}/gallery`} className={({ isActive }) => isActive ? styles.active : styles.navLink}>
              <SessionIcon />
              <span>{t('nav.currentSession')}</span>
            </NavLink>
          </li>
        )}
        <li className={styles.navItem}>
          <NavLink to="/library" className={({ isActive }) => isActive ? styles.active : styles.navLink}>
            <LibraryIcon />
            <span>{t('nav.library')}</span>
          </NavLink>
        </li>
        <li className={styles.navItem}>
          <NavLink to="/persons" className={({ isActive }) => isActive ? styles.active : styles.navLink}>
            <PersonsIcon />
            <span>{t('nav.persons')}</span>
          </NavLink>
        </li>
        <li className={styles.navItem}>
          <NavLink to="/jobs" className={({ isActive }) => isActive ? styles.active : styles.navLink}>
            <JobsIcon />
            <span>{t('nav.jobs')}</span>
          </NavLink>
        </li>
      </ul>
      <div className={styles.bottomNav}>
        <NavLink to="/settings" className={({ isActive }) => isActive ? styles.active : styles.navLink}>
          <SettingsIcon />
          <span>{t('nav.settings')}</span>
        </NavLink>
      </div>
    </nav>
  )
}
