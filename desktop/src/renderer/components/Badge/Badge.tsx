import React from 'react'
import { useTranslation, type TranslationKey } from '../../locales'
import styles from './Badge.module.css'

interface BadgeProps {
  status: string
  label?: string
}

const STATUS_COLORS: Record<string, string> = {
  idle: styles.idle,
  running: styles.running,
  done: styles.done,
  failed: styles.failed,
  cancelled: styles.cancelled,
  draft: styles.draft,
  review: styles.review,
  completed: styles.completed,
  photos_loaded: styles.photosLoaded,
  analyzing: styles.analyzing,
  partial: styles.partial,
  cleaned: styles.cleaned,
}

const STATUS_LABEL_KEYS: Record<string, TranslationKey> = {
  draft: 'badge.draft',
  photos_loaded: 'badge.photosLoaded',
  analyzing: 'badge.analyzing',
  review: 'badge.review',
  completed: 'badge.completed',
  failed: 'badge.failed',
  running: 'badge.running',
  done: 'badge.done',
  idle: 'badge.idle',
  cancelled: 'badge.cancelled',
  partial: 'badge.partial',
  cleaned: 'badge.cleaned',
}

export default function Badge({ status, label }: BadgeProps) {
  const { t } = useTranslation()
  const colorClass = STATUS_COLORS[status] ?? styles.default
  const fallbackLabel = STATUS_LABEL_KEYS[status]
    ? t(STATUS_LABEL_KEYS[status])
    : status

  return (
    <span className={`${styles.badge} ${colorClass}`}>
      {label ?? fallbackLabel}
    </span>
  )
}
