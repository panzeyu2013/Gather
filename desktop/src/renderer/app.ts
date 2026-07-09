// src/renderer/app.ts
// SPA 入口

import './styles/style.css'
import { engine } from './api'
import { $, $$ } from './components/dom'
import { dialog } from './components/dialog'
import { toast } from './components/toast'
import { setNavigate, runCleanup, type PageName } from './router'
import { renderDashboard, setupDashboard } from './pages/dashboard'
import { renderSimilarity, setupSimilarity } from './pages/similarity'
import { renderFaceKeywording, setupFaceKeywording } from './pages/face-kw'
import { ENGINE_TIMEOUT_MS } from '@gather/shared'

const ORDER = ['dashboard', 'similarity', 'face-kw'] as const
let sessionId: string | null = null
let pendingCaptureOneImport = false

export function clearSessionId(): void { sessionId = null; updateStepperAvailability(false); persistSession() }

export function getSessionId(): string | null { return sessionId }
export function consumeCaptureOneImportTrigger(): boolean {
  const pending = pendingCaptureOneImport
  pendingCaptureOneImport = false
  return pending
}

export function onEngineReady(cb: () => void): () => void {
  return window.gather.onReady(cb)
}

function persistSession(): void {
  try {
    if (sessionId) {
      sessionStorage.setItem('gather_sessionId', sessionId)
    } else {
      sessionStorage.removeItem('gather_sessionId')
    }
    sessionStorage.setItem('gather_lastPage', location.hash || '')
  } catch { /* sessionStorage may be unavailable */ }
}

function updateStepperAvailability(hasSession: boolean): void {
  $$('#sidebar .app-nav-item[data-page="similarity"], #sidebar .app-nav-item[data-page="face-kw"]').forEach(el => {
    el.classList.toggle('app-nav-item--disabled', !hasSession)
    if (hasSession) {
      el.removeAttribute('aria-disabled')
      el.removeAttribute('title')
      ;(el as HTMLButtonElement).disabled = false
    } else {
      ;(el as HTMLButtonElement).disabled = true
    }
  })
}

async function navigateInternal(page: PageName, sid?: string): Promise<void> {
  if (page !== 'dashboard' && !sid && !sessionId) { toast('Create a session first.', 'warning'); return }
  runCleanup(); if (sid) { sessionId = sid; persistSession(); updateStepperAvailability(true) }
  location.hash = page; persistSession()

  $$('#sidebar .app-nav-item').forEach(el => {
    const p = (el as HTMLElement).dataset.page as PageName | undefined
    if (!p) return
    const isActive = p === page
    el.classList.toggle('app-nav-item--active', isActive)
    if (isActive) el.setAttribute('aria-current', 'page')
    else el.removeAttribute('aria-current')
  })

  const contentEl = $('#content')!
  contentEl.classList.add('loading')
  try {
    switch (page) {
      case 'dashboard':  contentEl.innerHTML = await renderDashboard(); break
      case 'similarity': contentEl.innerHTML = await renderSimilarity(sessionId ?? ''); break
      case 'face-kw':    contentEl.innerHTML = await renderFaceKeywording(sessionId ?? ''); break
    }
  } catch (err) {
    console.error(err)
    contentEl.innerHTML = `<div class="state-panel" role="alert"><div class="state-panel__icon">&#9888;</div><div class="state-panel__title">Failed to load</div><div class="state-panel__body">Please try again.</div><button class="btn btn--primary mt-2" id="btnRetryPage">Retry</button></div>`
    $('#btnRetryPage')?.addEventListener('click', () => safeNav(page, sid).catch(console.error))
    contentEl.classList.remove('loading')
    return
  }

  const setupFns: Record<PageName, () => Promise<void>> = {
    dashboard:  async () => { setupDashboard() },
    similarity: async () => { setupSimilarity() },
    'face-kw':  async () => { setupFaceKeywording() },
  }
  try {
    await setupFns[page]()
  } catch (err) {
    console.error('setup failed:', err)
    contentEl.innerHTML = `<div class="state-panel" role="alert"><div class="state-panel__icon">&#9888;</div><div class="state-panel__title">Failed to initialize</div><div class="state-panel__body">Please try again.</div><button class="btn btn--primary mt-2" id="btnRetryPage">Retry</button></div>`
    $('#btnRetryPage')?.addEventListener('click', () => safeNav(page, sid).catch(console.error))
    contentEl.classList.remove('loading')
    return
  }
  contentEl.classList.remove('loading')
  const h1 = contentEl.querySelector('h1')
  if (h1) { h1.setAttribute('tabindex', '-1'); (h1 as HTMLElement).focus() }
}

async function safeNav(page: PageName, sid?: string): Promise<void> {
  const simRunning = document.querySelector('#simRunning:not(.hidden)')
  const fkwRunning = document.querySelector('#fkwProgWrap:not(.hidden)')
  if ((simRunning || fkwRunning) && !await dialog('Analysis is in progress. Stop and navigate away?')) return

  // Warn if navigating away from face-kw with possible unsaved work
  if (page !== 'face-kw' && document.querySelector('.fkw-panel[data-panel="2"].active')) {
    if (!await dialog('Unsaved changes may be lost. Navigate away?')) return
  }
  navigateInternal(page, sid).catch(console.error)
}
setNavigate(safeNav)

document.addEventListener('DOMContentLoaded', () => {
  if (!window.gather) {
    document.getElementById('loadingScreen')?.querySelector('.spinner')?.classList.add('hidden')
    document.querySelector('#loadingScreen > div:not(#engineError)')?.classList?.add('hidden')
    const error = document.getElementById('engineError')
    error?.classList.remove('hidden')
    const title = error?.querySelector('div:first-child')
    const detail = error?.querySelector('div:nth-child(2)')
    if (title) title.textContent = 'Electron preload API unavailable.'
    if (detail) detail.textContent = 'Open Gather through the Electron app so the renderer can connect to the Python engine.'
    $('#btnRetryEngine')?.addEventListener('click', () => location.reload())
    return
  }

  $$('#sidebar .app-nav-item').forEach(el => {
    const page = (el as HTMLElement).dataset.page as PageName
    if (!page) return
    el.addEventListener('click', () => {
      if (el.classList.contains('app-nav-item--disabled')) return
      safeNav(page, page !== 'dashboard' ? sessionId ?? undefined : undefined).catch(console.error)
    })
  })
  const unsubImportTrigger = window.gather.onEvent('c1:import-trigger', () => {
    pendingCaptureOneImport = true
    safeNav('dashboard').catch(console.error)
  })
  const stillLoadingTimer = setTimeout(() => {
    document.getElementById('stillLoading')?.classList.remove('hidden')
  }, 15000)

  const engineTimeout = setTimeout(() => {
    document.getElementById('loadingScreen')?.querySelector('.spinner')?.classList.add('hidden')
    document.querySelector('#loadingScreen > div:not(#engineError)')?.classList?.add('hidden')
    document.getElementById('engineError')?.classList.remove('hidden')
    $('#btnRetryEngine')?.addEventListener('click', () => location.reload())
  }, ENGINE_TIMEOUT_MS)

  const unsubReady = window.gather.onReady(async () => {
    clearTimeout(stillLoadingTimer)
    clearTimeout(engineTimeout)
    updateStepperAvailability(false)
    document.getElementById('loadingScreen')?.classList.add('hidden')
    document.getElementById('mainUi')?.classList.remove('hidden')
    const storedSid = sessionStorage.getItem('gather_sessionId')
    const storedPage = sessionStorage.getItem('gather_lastPage')
    if (storedSid && storedPage && ORDER.includes(storedPage as PageName)) {
      try {
        await engine.session.get(storedSid)
        safeNav(storedPage as PageName, storedSid).catch(console.error)
      } catch {
        safeNav('dashboard').catch(console.error)
      }
    } else {
      safeNav('dashboard').catch(console.error)
    }
  })

  const unsubDisconnected = window.gather.onEvent('python:disconnected', () => {
    toast('The processing engine has stopped unexpectedly. The application will attempt to restart.', 'error', 30000)
  })
  window.addEventListener('beforeunload', () => {
    unsubImportTrigger()
    unsubReady()
    unsubDisconnected()
  }, { once: true })
})
