import React, { useEffect, useRef } from 'react'
import styles from './Dialog.module.css'

interface DialogProps {
  open: boolean
  onClose: () => void
  title: string
  children: React.ReactNode
}

export default function Dialog({ open, onClose, title, children }: DialogProps) {
  const overlayRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    if (open) document.addEventListener('keydown', handleKey)
    return () => document.removeEventListener('keydown', handleKey)
  }, [open, onClose])

  if (!open) return null

  return (
    <div className={styles.overlay} ref={overlayRef} onClick={(e) => {
      if (e.target === overlayRef.current) onClose()
    }}>
      <div className={styles.dialog} role="dialog" aria-modal="true" aria-label={title}>
        <div className={styles.header}>
          <h2 className={styles.title}>{title}</h2>
          <button className={styles.close} onClick={onClose} aria-label="Close">&times;</button>
        </div>
        <div className={styles.body}>{children}</div>
      </div>
    </div>
  )
}
