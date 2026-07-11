import React from 'react'
import type { ToastItem } from './ToastStore'
import styles from './Toast.module.css'

interface ToastProps {
  toast: ToastItem
  onDismiss: (id: string) => void
}

export default function Toast({ toast, onDismiss }: ToastProps) {
  return (
    <div className={`${styles.toast} ${styles[toast.type]}`} role="alert">
      <span className={styles.message}>{toast.message}</span>
      <button className={styles.dismiss} onClick={() => onDismiss(toast.id)} aria-label="Dismiss">
        &times;
      </button>
    </div>
  )
}
