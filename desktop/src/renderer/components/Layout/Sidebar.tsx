import React from 'react'
import { NavLink } from 'react-router-dom'
import { useSessionStore } from '../../stores/sessionStore'
import styles from './Sidebar.module.css'

export default function Sidebar() {
  const sessionId = useSessionStore((s) => s.currentSessionId)

  const simTo = sessionId ? `/similarity/${sessionId}` : '/similarity/new'
  const fkwTo = sessionId ? `/face-kw/${sessionId}` : '/face-kw/new'

  return (
    <nav className={styles.sidebar}>
      <div className={styles.brand}>Gather</div>
      <ul className={styles.nav}>
        <li>
          <NavLink to="/" end className={({ isActive }) => isActive ? styles.active : ''}>
            工作台
          </NavLink>
        </li>
        <li>
          <NavLink to={simTo} className={({ isActive }) => isActive ? styles.active : ''}>
            相似度
          </NavLink>
        </li>
        <li>
          <NavLink to={fkwTo} className={({ isActive }) => isActive ? styles.active : ''}>
            人脸关键词
          </NavLink>
        </li>
      </ul>
    </nav>
  )
}
