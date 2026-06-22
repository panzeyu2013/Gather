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

export function typedConfirmDialog(message: string, requiredText: string, confirmLabel?: string): Promise<boolean> {
  const okLabel = confirmLabel || 'Confirm'
  const previousFocus = document.activeElement as HTMLElement | null
  return new Promise(resolve => {
    const overlay = document.createElement('div')
    overlay.className = 'dialog-overlay'

    overlay.innerHTML = `
      <div class="dialog-box" role="alertdialog" aria-modal="true" aria-labelledby="dialogTitle" aria-describedby="dialogMessage">
        <div class="dialog-title" id="dialogTitle">Confirm</div>
        <div class="dialog-message" id="dialogMessage">${esc(message)}</div>
        <label class="dialog-message" for="dialogTypedInput" style="display:block;margin-top:0.75rem">Type <strong>${esc(requiredText)}</strong> to continue.</label>
        <input id="dialogTypedInput" type="text" autocomplete="off" spellcheck="false" style="width:100%;margin-top:0.5rem;padding:0.65rem;border-radius:8px;border:1px solid var(--border);background:var(--bg);color:var(--text)">
        <div class="dialog-actions">
          <button class="dialog-btn dialog-btn--cancel" id="dialogCancel">Cancel</button>
          <button class="dialog-btn dialog-btn--ok" id="dialogOk" disabled>${esc(okLabel)}</button>
        </div>
      </div>`

    document.body.appendChild(overlay)

    const okBtn = overlay.querySelector('#dialogOk') as HTMLButtonElement
    const cancelBtn = overlay.querySelector('#dialogCancel') as HTMLButtonElement
    const input = overlay.querySelector('#dialogTypedInput') as HTMLInputElement
    const focusables: HTMLElement[] = [input, cancelBtn, okBtn]

    function close(): void {
      overlay.remove()
      document.removeEventListener('keydown', handleKey)
      if (previousFocus && typeof previousFocus.focus === 'function') {
        previousFocus.focus()
      }
    }

    function handleKey(e: KeyboardEvent): void {
      if (e.key === 'Escape') { resolve(false); close() }
      if (e.key === 'Enter' && document.activeElement === input && input.value === requiredText) {
        resolve(true); close()
      }
      if (e.key === 'Tab') {
        e.preventDefault()
        let idx = focusables.indexOf(document.activeElement as HTMLElement)
        if (idx === -1) idx = 0
        const next = e.shiftKey
          ? (idx - 1 + focusables.length) % focusables.length
          : (idx + 1) % focusables.length
        focusables[next].focus()
      }
    }

    document.addEventListener('keydown', handleKey)
    input.addEventListener('input', () => { okBtn.disabled = input.value !== requiredText })
    okBtn.addEventListener('click', () => { if (!okBtn.disabled) { resolve(true); close() } })
    cancelBtn.addEventListener('click', () => { resolve(false); close() })
    overlay.addEventListener('click', (e) => { if (e.target === overlay) { resolve(false); close() } })

    input.focus()
  })
}
