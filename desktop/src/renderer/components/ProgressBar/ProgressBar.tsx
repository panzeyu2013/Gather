import React from 'react'
import { useTranslation } from '../../locales'
import styles from './ProgressBar.module.css'

interface ProgressBarProps {
  value: number
  max?: number
  label?: string
}

export default function ProgressBar({ value, max = 100, label }: ProgressBarProps) {
  const { t } = useTranslation()
  const indeterminate = max <= 0 || !Number.isFinite(value / max)
  const pct = indeterminate ? 0 : Math.min(Math.round((value / max) * 100), 100)

  return (
    <div className={styles.wrapper}>
      {label && <span className={styles.label}>{label}</span>}
      <div
        className={styles.track}
        role="progressbar"
        aria-valuenow={indeterminate ? undefined : value}
        aria-valuemin={0}
        aria-valuemax={max}
      >
        <div
          className={indeterminate ? styles.fillIndeterminate : styles.fill}
          style={indeterminate ? undefined : { width: `${pct}%` }}
        />
      </div>
      <span className={styles.pct}>{indeterminate ? t('progressBar.inProgress') : `${pct}%`}</span>
    </div>
  )
}
