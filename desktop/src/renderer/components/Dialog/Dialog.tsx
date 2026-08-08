import React, { useEffect, useId, useRef } from 'react'
import { createPortal } from 'react-dom'
import { useTranslation } from '../../locales'
import styles from './Dialog.module.css'

interface DialogProps {
  open: boolean
  onClose: () => void
  title: string
  children: React.ReactNode
  initialFocus?: React.RefObject<HTMLElement | null>
  descriptionId?: string
}

const FOCUSABLE_SELECTOR =
  'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'

let openDialogCount = 0

function syncBackgroundInert(): void {
  const background = document.querySelector('main')
  if (!background) return
  if (openDialogCount > 0) background.setAttribute('inert', '')
  else background.removeAttribute('inert')
}

export default function Dialog({ open, onClose, title, children, initialFocus, descriptionId }: DialogProps) {
  const { t } = useTranslation()
  const overlayRef = useRef<HTMLDivElement>(null)
  const panelRef = useRef<HTMLDivElement>(null)
  const restoreFocusRef = useRef<HTMLElement | null>(null)
  const titleId = useId()

  useEffect(() => {
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    if (open) document.addEventListener('keydown', handleKey)
    return () => document.removeEventListener('keydown', handleKey)
  }, [open, onClose])

  useEffect(() => {
    if (!open) return
    restoreFocusRef.current = document.activeElement as HTMLElement | null
    const panel = panelRef.current
    const focusTarget =
      initialFocus?.current ??
      panel?.querySelector<HTMLElement>(FOCUSABLE_SELECTOR)
    if (focusTarget) focusTarget.focus({ preventScroll: true })
    else panel?.focus({ preventScroll: true })
    openDialogCount += 1
    syncBackgroundInert()
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key !== 'Tab' || !panel) return
      const focusables = Array.from(
        panel.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR),
      ).filter((el) => !(el as { disabled?: boolean }).disabled)
      if (focusables.length === 0) {
        e.preventDefault()
        return
      }
      const first = focusables[0]
      const last = focusables[focusables.length - 1]
      if (e.shiftKey && document.activeElement === first) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && document.activeElement === last) {
        e.preventDefault()
        first.focus()
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      openDialogCount -= 1
      syncBackgroundInert()
      restoreFocusRef.current?.focus({ preventScroll: true })
      restoreFocusRef.current = null
    }
  }, [open, initialFocus])

  if (!open) return null

  return createPortal(
    <div className={styles.overlay} ref={overlayRef} onClick={(e) => {
      if (e.target === overlayRef.current) onClose()
    }}>
      <div
        className={styles.dialog}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        {...(descriptionId ? { 'aria-describedby': descriptionId } : {})}
        ref={panelRef}
        tabIndex={-1}
      >
        <div className={styles.header}>
          <h2 className={styles.title} id={titleId}>{title}</h2>
          <button className={styles.close} onClick={onClose} aria-label={t('dialog.close')}>&times;</button>
        </div>
        <div className={styles.body}>{children}</div>
      </div>
    </div>,
    document.body,
  )
}
