import React from 'react'
import styles from './ProgressBar.module.css'

interface ProgressBarProps {
  value: number
  max?: number
  label?: string
}

export default function ProgressBar({ value, max = 100, label }: ProgressBarProps) {
  const pct = Math.min(Math.round((value / max) * 100), 100)

  return (
    <div className={styles.wrapper}>
      {label && <span className={styles.label}>{label}</span>}
      <div className={styles.track} role="progressbar" aria-valuenow={value} aria-valuemin={0} aria-valuemax={max}>
        <div className={styles.fill} style={{ width: `${pct}%` }} />
      </div>
      <span className={styles.pct}>{pct}%</span>
    </div>
  )
}
