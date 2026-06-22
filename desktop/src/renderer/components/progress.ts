// src/renderer/components/progress.ts
// RAF-throttled progress bar rendering utility

import { $ } from './dom'

export function createProgressRenderer(barSelector: string, textSelector: string) {
  let pending = false
  let latestPct = 0
  let latestMessage = ''
  let rafId: number | null = null

  const flush = () => {
    rafId = null
    const bar = $(barSelector)
    if (bar) {
      bar.style.width = latestPct + '%'
      const progressEl = bar.closest('[role="progressbar"]')
      if (progressEl) { progressEl.setAttribute('aria-valuenow', String(latestPct)) }
    }
    const text = $(textSelector)
    if (text) text.textContent = latestMessage
    pending = false
  }

  const updateProgress = (pct: number, message: string) => {
    latestPct = Math.min(100, Math.max(0, Math.round(pct)))
    latestMessage = message
    if (!pending) {
      pending = true
      rafId = requestAnimationFrame(flush)
    }
  }

  const dispose = () => {
    pending = false
    if (rafId !== null) {
      cancelAnimationFrame(rafId)
      rafId = null
    }
  }

  return { updateProgress, flush, dispose }
}
