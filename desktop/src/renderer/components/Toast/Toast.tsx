import React from 'react'
import type { ToastItem } from './ToastStore'
import { useTranslation } from '../../locales'
import styles from './Toast.module.css'

interface ToastProps {
  toast: ToastItem
  onDismiss: (id: string) => void
}

export default function Toast({ toast, onDismiss }: ToastProps) {
  const { t } = useTranslation()
  return (
    <div
      className={`${styles.toast} ${styles[toast.type]}`}
      role={toast.type === 'error' ? 'alert' : 'status'}
      aria-live={toast.type === 'error' ? 'assertive' : 'polite'}
    >
      <span className={styles.message}>{toast.message}</span>
      <button className={styles.dismiss} onClick={() => onDismiss(toast.id)} aria-label={t('toast.dismiss')}>
        &times;
      </button>
    </div>
  )
}
