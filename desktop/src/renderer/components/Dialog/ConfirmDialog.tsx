import React from 'react'
import Dialog from './Dialog'
import styles from './ConfirmDialog.module.css'

interface ConfirmDialogProps {
  open: boolean
  onClose: () => void
  onConfirm: () => void
  title: string
  message: string
  confirmLabel?: string
  cancelLabel?: string
  destructive?: boolean
}

export default function ConfirmDialog({
  open,
  onClose,
  onConfirm,
  title,
  message,
  confirmLabel = '确认',
  cancelLabel = '取消',
  destructive = false,
}: ConfirmDialogProps) {
  return (
    <Dialog open={open} onClose={onClose} title={title}>
      <p className={styles.message}>{message}</p>
      <div className={styles.actions}>
        <button className={styles.cancel} onClick={onClose}>{cancelLabel}</button>
        <button
          className={`${styles.confirm} ${destructive ? styles.destructive : ''}`}
          onClick={() => { onConfirm(); onClose() }}
        >
          {confirmLabel}
        </button>
      </div>
    </Dialog>
  )
}
