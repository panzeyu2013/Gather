import React from 'react'
import { NavLink } from 'react-router-dom'
import { useSessionStore } from '../../stores/sessionStore'
import styles from './Sidebar.module.css'

export default function Sidebar() {
  const sessionId = useSessionStore((s) => s.currentSessionId)

  return (
    <nav className={styles.sidebar}>
      <div className={styles.brand}>Gather</div>
      <ul className={styles.nav}>
        <li>
          <NavLink to="/" end className={({ isActive }) => isActive ? styles.active : ''}>
            工作台
          </NavLink>
        </li>
        {sessionId && (
          <li>
            <NavLink to={`/sessions/${sessionId}/gallery`} className={({ isActive }) => isActive ? styles.active : ''}>
              当前会话
            </NavLink>
          </li>
        )}
      </ul>
      <div className={styles.bottomNav}>
        <NavLink to="/settings" className={({ isActive }) => isActive ? styles.active : styles.settingsBtn}>
          &#9881;
        </NavLink>
      </div>
    </nav>
  )
}
