// src/renderer/components/dialog.ts
// Custom dialog replacing native confirm()

import { esc } from './dom'

export function dialog(message: string, confirmLabel?: string): Promise<boolean> {
  const okLabel = confirmLabel || 'OK'
  const previousFocus = document.activeElement as HTMLElement | null
  return new Promise(resolve => {
    const overlay = document.createElement('div')
    overlay.className = 'dialog-overlay'

    overlay.innerHTML = `
      <div class="dialog-box" role="alertdialog" aria-modal="true" aria-labelledby="dialogTitle" aria-describedby="dialogMessage">
        <div class="dialog-title" id="dialogTitle">Confirm</div>
        <div class="dialog-message" id="dialogMessage">${esc(message)}</div>
        <div class="dialog-actions">
          <button class="dialog-btn dialog-btn--cancel" id="dialogCancel">Cancel</button>
          <button class="dialog-btn dialog-btn--ok" id="dialogOk">${esc(okLabel)}</button>
        </div>
      </div>`

    document.body.appendChild(overlay)

    const okBtn = overlay.querySelector('#dialogOk') as HTMLButtonElement
    const cancelBtn = overlay.querySelector('#dialogCancel') as HTMLButtonElement
    const buttons = [okBtn, cancelBtn]

    function close(): void {
      overlay.remove()
      document.removeEventListener('keydown', handleKey)
      if (previousFocus && typeof previousFocus.focus === 'function') {
        previousFocus.focus()
      }
    }

    function handleKey(e: KeyboardEvent): void {
      if (e.key === 'Escape') { resolve(false); close() }
      if (e.key === 'Tab') {
        e.preventDefault()
        let idx = buttons.indexOf(document.activeElement as HTMLButtonElement)
        if (idx === -1) idx = 0
        const next = e.shiftKey
          ? (idx - 1 + buttons.length) % buttons.length
          : (idx + 1) % buttons.length
        buttons[next].focus()
      }
    }

    document.addEventListener('keydown', handleKey)

    okBtn.addEventListener('click', () => { resolve(true); close() })
    cancelBtn.addEventListener('click', () => { resolve(false); close() })

    okBtn.focus()

    overlay.addEventListener('click', (e) => { if (e.target === overlay) { resolve(false); close() } })
  })
}
