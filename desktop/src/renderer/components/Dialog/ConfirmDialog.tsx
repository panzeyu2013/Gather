import React, { useRef } from 'react'
import Dialog from './Dialog'
import { useTranslation } from '../../locales'
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
  confirmLabel,
  cancelLabel,
  destructive = false,
}: ConfirmDialogProps) {
  const { t } = useTranslation()
  const cancelRef = useRef<HTMLButtonElement>(null)
  return (
    <Dialog
      open={open}
      onClose={onClose}
      title={title}
      initialFocus={cancelRef}
    >
      <p className={styles.message}>{message}</p>
      <div className={styles.actions}>
        <button ref={cancelRef} className={styles.cancel} onClick={onClose}>{cancelLabel ?? t('common.cancel')}</button>
        <button
          className={`${styles.confirm} ${destructive ? styles.destructive : ''}`}
          onClick={() => { onConfirm(); onClose() }}
        >
          {confirmLabel ?? t('common.confirm')}
        </button>
      </div>
    </Dialog>
  )
}
