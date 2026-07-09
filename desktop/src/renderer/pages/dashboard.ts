// src/renderer/pages/dashboard.ts

import { engine, c1, app, showError, assertRecordResponse } from '../api'
import { clearSessionId, consumeCaptureOneImportTrigger } from '../app'
import { dialog, typedConfirmDialog } from '../components/dialog'
import { $, $$, esc, on } from '../components/dom'
import { toast } from '../components/toast'
import { navigate, registerCleanup } from '../router'
import type { SessionData } from '@gather/shared'

let gSessions: SessionData[] = []
let loadError = false

function statusBadge(s: SessionData): string {
  const badges: string[] = []
  
  // Import source badge
  const sourceLabel = s.import_source === 'capture_one' ? 'Capture One' : s.import_source === 'local_files' ? 'Local Files' : ''
  if (sourceLabel) {
    badges.push(`<span class="badge badge--source">${sourceLabel}</span>`)
  }
  
  // Status badge
  badges.push(`<span class="badge badge--${esc(s.status)}">${esc(s.status)}</span>`)
  
  // Analysis badge
  if (s.analysis_status === 'done') {
    badges.push('<span class="badge badge--analyzed">Analyzed</span>')
  }
  
  // Writeback badges
  if (s.writeback_status === 'done') {
    badges.push('<span class="badge badge--writeback-done">Writeback done</span>')
  } else if (s.writeback_status === 'partial') {
    badges.push('<span class="badge badge--writeback-partial">Writeback partial</span>')
  } else if (s.writeback_status === 'cleaned') {
    badges.push('<span class="badge badge--cleaned">Cleaned</span>')
  }
  
  // Failed count
  if (s.failed_writeback_count && s.failed_writeback_count > 0) {
    badges.push(`<span class="badge badge--failed">${s.failed_writeback_count} failed</span>`)
  }
  
  return badges.join(' ')
}

function renderSessionRows(sessions: SessionData[]): string {
  return sessions.map(s => `
    <div class="session-row" data-sid="${esc(s.id)}">
      <div class="session-row__info">
        <div class="session-row__name">${esc(s.name || 'Untitled')}</div>
        <div class="session-row__meta">
          ${esc((s.created_at || '').slice(0, 16).replace('T', ' '))}
          ${s.photo_count ? ` &middot; ${s.photo_count} photos` : ''}
        </div>
      </div>
      <div class="session-row__status">
        ${statusBadge(s)}
      </div>
      <div class="session-row__actions">
        <button class="btn btn--secondary btn--sm" data-act="sim" data-sid="${esc(s.id)}">Similarity</button>
        <button class="btn btn--secondary btn--sm" data-act="fkw" data-sid="${esc(s.id)}">Face KW</button>
        <button class="btn btn--sm" data-act="del" data-sid="${esc(s.id)}" style="color:var(--text-danger)" aria-label="Delete session">Delete</button>
      </div>
    </div>`).join('')
}

function renderSummary(sessions: SessionData[]): string {
  const total = sessions.length
  const needsReview = sessions.filter(s => s.writeback_status === 'partial' || (s.failed_writeback_count && s.failed_writeback_count > 0)).length
  const completed = sessions.filter(s => s.writeback_status === 'done' || s.writeback_status === 'cleaned').length
  const failed = sessions.filter(s => s.failed_writeback_count && s.failed_writeback_count > 0).length
  return `
    <div class="dashboard-summary">
      <div class="dashboard-summary__item" aria-label="${total} total sessions"><span class="dashboard-summary__count">${total}</span> sessions</div>
      ${needsReview ? `<div class="dashboard-summary__item dashboard-summary__item--warning" aria-label="${needsReview} sessions need review"><span class="dashboard-summary__count">${needsReview}</span> need review</div>` : ''}
      ${failed ? `<div class="dashboard-summary__item dashboard-summary__item--danger" aria-label="${failed} sessions with writeback failures"><span class="dashboard-summary__count">${failed}</span> with failures</div>` : ''}
      ${completed ? `<div class="dashboard-summary__item dashboard-summary__item--success" aria-label="${completed} completed sessions"><span class="dashboard-summary__count">${completed}</span> completed</div>` : ''}
    </div>`
}

export async function renderDashboard(): Promise<string> {
  const content = document.getElementById('content')
  if (content) {
    content.innerHTML = `<div class="empty-state"><div class="spinner"></div><div class="empty-state__text mt-1">Loading sessions…</div></div>`
  }
  try { gSessions = await engine.session.list(); loadError = false } catch (err: unknown) { console.error('Failed to load sessions:', err); loadError = true; gSessions = [] }

  const rows = renderSessionRows(gSessions)

  return `
    <div class="dashboard">
      <div class="dashboard-header">
        <h1 class="dashboard-header__title">Sessions</h1>
        <div class="dashboard-header__actions">
          <button class="btn btn--primary" id="btnImportC1">Import from Capture One</button>
          <button class="btn btn--secondary" id="btnImportFiles">Import Files…</button>
        </div>
      </div>
      ${gSessions.length ? `
        ${renderSummary(gSessions)}
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem;flex-wrap:wrap;gap:0.5rem">
          <div class="segmented-control">
            <button class="segmented-control__btn active" data-filter="all">All</button>
            <button class="segmented-control__btn" data-filter="needs-review">Needs Review</button>
            <button class="segmented-control__btn" data-filter="completed">Completed</button>
          </div>
          <button class="btn btn--sm" id="btnClearAll" style="color:var(--text-danger)">Delete All</button>
        </div>
        <div aria-live="polite"><div class="session-list">${rows}</div></div>
      ` : (loadError ? `
        <div class="state-panel" role="alert">
          <div class="state-panel__icon">&#9888;</div>
          <div class="state-panel__title">Failed to load sessions</div>
          <div class="state-panel__body">Could not connect to the server.</div>
          <button class="btn btn--primary mt-2" id="btnRetryLoad">Retry</button>
        </div>
      ` : `
        <div class="state-panel" role="alert">
          <div class="state-panel__icon">&#128247;</div>
          <div class="state-panel__title">No sessions yet</div>
          <div class="state-panel__body">Select images in Capture One, then click "Import from Capture One" to create your first session.</div>
        </div>
      `)}
    </div>`
}

export function setupDashboard(): void {
  const content = document.getElementById('content')
  if (!content) return
  const cleanups: (() => void)[] = []

  const importPhotos = async (getPhotos: () => Promise<string[]>, source: string) => {
    const btnC1 = $('#btnImportC1') as HTMLButtonElement | null
    const btnFiles = $('#btnImportFiles') as HTMLButtonElement | null
    if (btnC1) { btnC1.disabled = true; btnC1.textContent = 'Importing…' }
    if (btnFiles) { btnFiles.disabled = true; btnFiles.textContent = 'Importing…' }
    try {
      const photos = await getPhotos()
      if (!photos.length) { toast('No photos selected.', 'warning'); return }
      const dir = photos[0].replace(/\\/g, '/').split('/').slice(0, -1).join('/').split('/').pop() || 'Session'
      const name = `${dir} - ${new Date().toISOString().slice(0, 10)}`
      const created = await engine.session.create(name)
      const result = assertRecordResponse(await engine.session.addPhotos(created.id, photos, source), 'session.add_photos') as Record<string, unknown>
      const actualAdded = typeof result.added === 'number' ? result.added : photos.length
      const failedPaths = Array.isArray(result.failed_paths) ? result.failed_paths as string[] : []
      if (failedPaths.length) {
        toast(`${failedPaths.length} files could not be imported`, 'warning')
      }
      toast(`Created "${name}" with ${actualAdded} photos`, 'success')
      gSessions = await engine.session.list()
      const rows = renderSessionRows(gSessions)
      const existingList = $('.session-list')
      if (existingList) {
        existingList.innerHTML = rows
      } else {
        const emptyState = $('.state-panel')
        if (emptyState) {
          const summaryHtml = renderSummary(gSessions)
          emptyState.outerHTML = `${summaryHtml}<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem;flex-wrap:wrap;gap:0.5rem"><div class="segmented-control"><button class="segmented-control__btn active" data-filter="all">All</button><button class="segmented-control__btn" data-filter="needs-review">Needs Review</button><button class="segmented-control__btn" data-filter="completed">Completed</button></div><button class="btn btn--sm" id="btnClearAll" style="color:var(--text-danger)">Delete All</button></div><div aria-live="polite"><div class="session-list">${rows}</div></div>`
        }
      }
    } catch (err: unknown) { showError(err, 'Import failed. Please check that Capture One is running and photos are selected, then try again.') }
    finally { if (btnC1) { btnC1.disabled = false; btnC1.textContent = 'Import from Capture One' } if (btnFiles) { btnFiles.disabled = false; btnFiles.textContent = 'Import Files…' } }
  }

  cleanups.push(on(content, 'click', '#btnImportC1', () => { importPhotos(() => c1.getSelectedPhotos(), 'capture_one') }))
  cleanups.push(on(content, 'click', '#btnImportFiles', () => { importPhotos(() => app.selectFiles(), 'local_files') }))
  cleanups.push(on(content, 'click', '#btnRetryLoad', async () => { navigate('dashboard') }))
  cleanups.push(on(content, 'click', '[data-act="sim"]', (el, e) => {
    e.preventDefault()
    const sid = el.dataset.sid; if (!sid) return
    navigate('similarity', sid)
  }))
  cleanups.push(on(content, 'click', '[data-act="fkw"]', (el, e) => {
    e.preventDefault()
    const sid = el.dataset.sid; if (!sid) return
    navigate('face-kw', sid)
  }))
  cleanups.push(on(content, 'click', '[data-act="del"]', async (el) => {
    const sid = el.dataset.sid; if (!sid) return
    const session = gSessions.find(s => s.id === sid)
    const sessionLabel = session?.name || sid.slice(0, 8) + '…'
    if (!await dialog(`Delete session "${sessionLabel}" and all its data?`, 'Delete')) return
    const btn = el as HTMLButtonElement
    btn.textContent = 'Deleting…'
    btn.disabled = true
    try {
      await engine.session.delete(sid)
      clearSessionId()
      try { sessionStorage.removeItem('gather_sessionId') } catch {}
      $(`.session-row[data-sid="${CSS.escape(sid)}"]`)?.remove()
      if (!$$('.session-row').length) navigate('dashboard')
    } catch (err: unknown) { btn.disabled = false; showError(err, 'Delete failed. The session may have already been removed.') }
  }))
  cleanups.push(on(content, 'click', '#btnClearAll', async function (this: HTMLButtonElement) {
    if (!await typedConfirmDialog('Delete ALL sessions and all local Gather data? This cannot be undone.', 'DELETE ALL', 'Delete All')) return
    this.disabled = true
    document.querySelectorAll<HTMLButtonElement>('[data-act="del"]').forEach(b => b.disabled = true)
    try {
      const r = await Promise.allSettled(gSessions.map(s => engine.session.delete(s.id)))
      const failed = r.filter(x => x.status === 'rejected').length
      clearSessionId()
      if (failed) toast(`${failed} failed to delete.`, 'warning')
      else toast('All sessions cleared.', 'success')
      navigate('dashboard')
    } catch (err: unknown) { showError(err, 'Bulk delete failed.') }
  }))

  if (consumeCaptureOneImportTrigger()) {
    void importPhotos(() => c1.getSelectedPhotos(), 'capture_one')
  }

  cleanups.push(on(content, 'click', '.segmented-control__btn', (el) => {
    $$('.segmented-control__btn').forEach(b => b.classList.remove('active'))
    el.classList.add('active')
    const filter = el.dataset.filter || 'all'
    const rows = $$('.session-row')
    rows.forEach(row => {
      const sid = (row as HTMLElement).dataset.sid || ''
      const s = gSessions.find(s => s.id === sid)
      if (!s) return
      let show = true
      if (filter === 'needs-review') {
        show = s.writeback_status === 'partial' || s.failed_writeback_count && s.failed_writeback_count > 0 || (s.analysis_status === 'done' && s.writeback_status === 'idle')
      } else if (filter === 'completed') {
        show = s.writeback_status === 'done' || s.writeback_status === 'cleaned'
      }
      (row as HTMLElement).style.display = show ? '' : 'none'
    })
  }))

  registerCleanup(() => cleanups.forEach(fn => fn()))
}
