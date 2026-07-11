import React from 'react'
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

const STATUS_LABELS: Record<string, string> = {
  draft: '草稿',
  photos_loaded: '已导入',
  analyzing: '分析中',
  review: '待审核',
  completed: '已完成',
  failed: '失败',
  running: '运行中',
  done: '完成',
  idle: '空闲',
  cancelled: '已取消',
  partial: '部分完成',
  cleaned: '已清理',
}

export default function Badge({ status, label }: BadgeProps) {
  const colorClass = STATUS_COLORS[status] ?? styles.default

  return (
    <span className={`${styles.badge} ${colorClass}`}>
      {label ?? STATUS_LABELS[status] ?? status}
    </span>
  )
}
