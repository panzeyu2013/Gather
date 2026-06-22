// src/renderer/components/toast.ts
// Toast 通知组件

export type ToastType = 'success' | 'error' | 'warning' | 'info' | ''

const MAX_TOASTS = 10

function getToastPriority(el: Element): number {
  if (el.classList.contains('toast--error')) return 0
  if (el.classList.contains('toast--warning')) return 1
  if (el.classList.contains('toast--success')) return 2
  return 3
}

export function toast(msg: string, type: ToastType = '', ms?: number): void {
  if (ms === undefined && type === 'error') { ms = 8000 }
  toastWithAction(msg, type, ms ?? 3500)
}

export interface ToastAction {
  label: string
  onClick: () => void
}

export function toastWithAction(msg: string, type: ToastType = '', ms = 3500, actions?: ToastAction[]): void {
  let c = document.querySelector<HTMLDivElement>('.toast-container')
  if (!c) { c = document.createElement('div'); c.className = 'toast-container'; document.body.appendChild(c) }
  while (c.children.length >= MAX_TOASTS) {
    let worst: Element | null = null
    let worstPriority = -1
    for (const child of c.children) {
      const p = getToastPriority(child)
      if (p > worstPriority) { worstPriority = p; worst = child }
    }
    worst?.remove()
  }
  const el = document.createElement('div')
  el.setAttribute('role', 'alert')
  el.setAttribute('aria-live', type === 'error' ? 'assertive' : 'polite')
  el.setAttribute('aria-atomic', 'true')
  el.className = 'toast' + (type ? ` toast--${type}` : '')
  el.innerHTML = ''
  const span = document.createElement('span')
  span.textContent = msg
  el.appendChild(span)
  if (actions?.length) {
    const actionsWrap = document.createElement('span')
    actionsWrap.className = 'toast__actions'
    actions.forEach(a => {
      const btn = document.createElement('button')
      btn.className = 'toast__action-btn'
      btn.textContent = a.label
      btn.addEventListener('click', () => {
        el.remove()
        a.onClick()
      })
      actionsWrap.appendChild(btn)
    })
    el.appendChild(actionsWrap)
  }
  c.appendChild(el)
  setTimeout(() => {
    el.classList.add('toast--out')
    const fallbackTimer = setTimeout(() => el.remove(), 500)
    // { once: true } ensures the listener self-removes after firing, preventing
    // memory leaks even if the toast element is removed externally before the event.
    el.addEventListener('animationend', () => { clearTimeout(fallbackTimer); if (el.isConnected) el.remove() }, { once: true })
  }, ms)
}
