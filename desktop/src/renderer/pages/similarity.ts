// src/renderer/pages/similarity.ts
// Similarity Groups — dHash + 聚类 + 写回

import { engine, showError } from '../api'
import { clearSessionId } from '../app'
import { dialog } from '../components/dialog'
import { $, esc, on, setText } from '../components/dom'
import { createProgressRenderer } from '../components/progress'
import { toast } from '../components/toast'
import { navigate, registerCleanup } from '../router'
import { createPollLoop } from '../utils/poll'
import { clampInteger, isValidBase64 } from '../utils/validation'
import { createEngineRestartHandler, type EngineRestartHandler } from '../utils/engine-restart'
import type { SimilarityGroup } from '@gather/shared'
import { AnalysisStatus } from '@gather/shared'
import {
  SIM_DEBOUNCE_MS,
  MAX_POLL_RETRIES_SIM,
  POLL_INTERVAL_SIM,
} from '@gather/shared'

let sessionId = ''
let groups: SimilarityGroup[] = []
let ungrouped: { path: string }[] = []
let stats: Record<string, number> = {}

let analysisComplete = false
let analysisInProgress = false
let loadingResults = false

let lastThreshold = 12
let lastMinGroup = 2
let sessionName = ''
let simModalPreviousFocus: HTMLElement | null = null

let _delegatedCleanups: (() => void)[] = []

const selectedGroupIds: Set<string> = new Set()
let hasUserTouchedSelection = false
let engineRestartUnsub: (() => void) | null = null
let enginePollRef: EngineRestartHandler['pollRef'] = { current: null }

function _cleanupDelegated(): void {
  _delegatedCleanups.forEach(fn => fn())
  _delegatedCleanups = []
}

const ALLOWED_OPTIONS = ['createAlbums', 'addPrefix', 'markUngrouped', 'writeIPTC']
const OPTION_LABELS: Record<string, string> = {
  createAlbums: 'Create Albums',
  addPrefix: 'Add Prefix',
  markUngrouped: 'Mark Ungrouped',
  writeIPTC: 'Write IPTC Keywords',
}

const THRESHOLD_MIN = 4
const THRESHOLD_MAX = 20
const THRESHOLD_DEFAULT = 12
const MIN_GROUP_MIN = 1
const MIN_GROUP_MAX = 10
const MIN_GROUP_DEFAULT = 2

export async function renderSimilarity(sid: string): Promise<string> {
  sessionId = sid; groups = []; ungrouped = []; stats = {}; enginePollRef.current?.stop()
  analysisComplete = false; analysisInProgress = false
  selectedGroupIds.clear()
  hasUserTouchedSelection = false
  try {
    const sessions = await engine.session.list()
    const s = sessions.find(s => s.id === sid)
    if (s) sessionName = s.name || ''
  } catch (err: unknown) { console.error('Failed to load session name', err); sessionName = '' }
  return `<div class="sim-root">
<div class="sim-header">
  <div class="sim-header__title">
    <button class="btn btn--secondary btn--sm" id="btnSimBack">← Dashboard</button>
    <button class="btn btn--danger btn--sm" id="btnSimDelete">Delete</button>
    <h1>Similarity Groups</h1>
  </div>
  <span class="sim-session-id" id="simSid">${esc(sessionName || sid.slice(0, 8) + '…')}</span>
</div>
<div class="sim-stage active" id="simProgress">
  <div class="sim-progress-full">
    <div id="simBefore" style="text-align:center">
      <div style="font-size:1.25rem;font-weight:600;margin-bottom:0.5rem">Ready to Analyze</div>
      <p style="color:var(--text-muted);margin-bottom:1.5rem">Click to compute hashes and group similar images.</p>
      <button class="btn btn--primary btn--lg" id="btnStartSim">Start Analysis</button>
      <button class="btn btn--warning btn--lg hidden" id="btnCancelSim">Cancel Analysis</button>
      <div style="margin-top:1rem;font-size:0.82rem;color:var(--text-dim)">
        Threshold: <strong id="preThresh">12</strong> · Min group: <strong id="preMin">2</strong>
      </div>
    </div>
    <div id="simRunning" class="hidden">
      <div class="sim-phase" id="phaseLabel">Computing…</div>
      <div class="progress" role="progressbar" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100" aria-label="Analysis progress"><div class="progress__fill" id="simFill" style="width:0%"></div></div>
      <div class="sim-current-file" id="simFile">Preparing…</div>
    </div>
  </div>
</div>
<div class="sim-stage" id="simResults">
  <div class="sim-stats">
    <div class="sim-stat"><div class="sim-stat__value" id="sTotal">0</div><div class="sim-stat__label">Total</div></div>
    <div class="sim-stat sim-stat--accent"><div class="sim-stat__value" id="sGrouped">0</div><div class="sim-stat__label">Grouped</div></div>
    <div class="sim-stat sim-stat--warning"><div class="sim-stat__value" id="sUngrouped">0</div><div class="sim-stat__label">Ungrouped</div></div>
    <div class="sim-stat sim-stat--success"><div class="sim-stat__value" id="sGroups">0</div><div class="sim-stat__label">Groups</div></div>
  </div>
  <div class="sim-controls">
    <div class="sim-control"><label for="simThresh">Threshold</label><input type="range" id="simThresh" min="${THRESHOLD_MIN}" max="${THRESHOLD_MAX}" value="${THRESHOLD_DEFAULT}" step="1"></div>
    <div class="sim-control"><label for="simMin">Min Group</label><input type="number" id="simMin" min="${MIN_GROUP_MIN}" max="${MIN_GROUP_MAX}" value="${MIN_GROUP_DEFAULT}"></div>
  </div>
  <div class="sim-groups-grid" id="simGrid"></div>
  <div class="sim-ungrouped">
    <button class="sim-toggle" id="simUngToggle" aria-expanded="false" aria-controls="simUngList">Ungrouped (<span id="simUngCnt">0</span>)</button>
    <div class="sim-ungrouped-list" id="simUngList" role="region" aria-label="Ungrouped images"></div>
  </div>
  <div class="sim-writeback-bar">
    <button class="sim-toggle-all" id="btnSelAll">Select All</button> |
    <button class="sim-toggle-all" id="btnDeselAll">Deselect All</button>
    ${ALLOWED_OPTIONS.map(opt => `<label class="sim-group-card__option" title="${({createAlbums:'Create Capture One albums for each similarity group',addPrefix:'Add Gather_group_N_ prefix to filenames',markUngrouped:'Tag ungrouped images with color label in Capture One',writeIPTC:'Write similarity group labels as IPTC keywords to XMP sidecar files'})[opt] || ''}"><input type="checkbox" class="sim-global-opt" data-option="${opt}">${OPTION_LABELS[opt] || opt}</label>`).join('')}
    <span style="flex:1"></span>
    <button class="btn btn--success" id="btnExecWb">Execute Writeback</button>
  </div>
</div>
  <div class="sim-modal" id="simModal" role="dialog" aria-modal="true" aria-labelledby="simModalTitle" aria-describedby="simReport">
  <div class="sim-modal__box" tabindex="-1"><h3 id="simModalTitle">Writeback Result</h3><pre id="simReport"></pre><div style="margin-top:1rem;text-align:right"><button class="btn btn--secondary" id="btnCloseModal">Close</button></div></div>
</div>
</div>`
}

export function setupSimilarity(): void {
  const content = document.getElementById('content')
  if (!content) { console.error('[similarity] content element not found'); return }
  const cleanups: (() => void)[] = []

  const restartHandler = createEngineRestartHandler(() => {
    analysisInProgress = false
    analysisComplete = false
    groups = []; ungrouped = []; stats = {}
    enginePollRef.current?.stop()
    resetSimUI()
    renderResults()
  })
  engineRestartUnsub = restartHandler.unsub
  enginePollRef = restartHandler.pollRef

  cleanups.push(on(content, 'click', '#btnSimBack', () => navigate('dashboard')))
  cleanups.push(on(content, 'click', '#btnSimDelete', async () => {
    if (!await dialog('Delete this session?', 'Delete')) return
    try { await engine.session.delete(sessionId); clearSessionId(); navigate('dashboard') } catch (err: unknown) { showError(err, 'Delete failed. The session may have already been removed.') }
  }))
  cleanups.push(on(content, 'click', '#btnStartSim', () => startAnalysis()))
  cleanups.push(on(content, 'click', '#btnCancelSim', async (el) => {
    const btn = el as HTMLButtonElement; btn.disabled = true; btn.textContent = 'Cancelling…'
    enginePollRef.current?.stop()
    try { await engine.sim.cancelAnalysis(sessionId); toast('Analysis cancelled.', 'warning') } catch (err: unknown) { showError(err, 'Cancel failed. Please try again.') }
    analysisComplete = false
    analysisInProgress = false
    const startBtn = $('#btnStartSim') as HTMLButtonElement | null
    if (startBtn) { startBtn.disabled = false; startBtn.textContent = 'Start Analysis'; startBtn.classList.remove('hidden') }
    const cancelBtn = $('#btnCancelSim') as HTMLElement | null
    if (cancelBtn) { cancelBtn.classList.add('hidden'); (cancelBtn as HTMLButtonElement).disabled = false; cancelBtn.textContent = 'Cancel Analysis' }
    const slider = $('#simThresh') as HTMLInputElement | null; if (slider) slider.disabled = false
    const minInp = $('#simMin') as HTMLInputElement | null; if (minInp) minInp.disabled = false
  }))
  cleanups.push(on(content, 'click', '#btnExecWb', () => executeWb()))
  cleanups.push(on(content, 'click', '#btnCloseModal', () => closeSimModal()))
  cleanups.push(on(content, 'click', '#simModal', (el, e) => { if (e.target === el) closeSimModal() }))
  const handleSimModalEscape = (e: KeyboardEvent) => {
    if (e.key === 'Escape') {
      const modal = $('#simModal')
      if (modal?.classList.contains('active')) { e.preventDefault(); closeSimModal() }
    }
  }
  document.addEventListener('keydown', handleSimModalEscape)
  cleanups.push(() => document.removeEventListener('keydown', handleSimModalEscape))
  cleanups.push(on(content, 'click', '#simUngToggle', () => {
    const list = $('#simUngList')
    const toggle = $('#simUngToggle')
    const isOpen = list?.classList.toggle('open')
    toggle?.classList.toggle('open')
    toggle?.setAttribute('aria-expanded', isOpen ? 'true' : 'false')
    if (isOpen && !ungrouped.length && list) {
      list.innerHTML = '<div class="empty-state__text" style="padding:1rem;text-align:center">No ungrouped images</div>'
    }
  }))

  let reclusterTimer: ReturnType<typeof setTimeout>
  const debouncedRecluster = () => { clearTimeout(reclusterTimer); reclusterTimer = setTimeout(recluster, SIM_DEBOUNCE_MS) }
  cleanups.push(on(content, 'input', '#simThresh', (el) => { setText('preThresh', (el as HTMLInputElement).value); debouncedRecluster() }))
  cleanups.push(on(content, 'input', '#simMin', (el) => { setText('preMin', (el as HTMLInputElement).value); debouncedRecluster() }))
  cleanups.push(on(content, 'focusout', '#simMin', () => { getSimilarityParams({ syncInputs: true }) }))
  cleanups.push(on(content, 'click', '#btnSelAll', () => setAllOpts(true)))
  cleanups.push(on(content, 'click', '#btnDeselAll', () => setAllOpts(false)))

  const progress = createProgressRenderer('#simFill', '#simFile')

  const unsubProgress = engine.onProgress(data => {
    if (data.session_id !== sessionId) return
    const pct = data.total > 0 ? (data.current / data.total) * 100 : 0
    progress.updateProgress(pct, data.message || '')
    const p = $('#phaseLabel')
    if (p) {
      const m = (data.message || '').toLowerCase()
      if (m.includes('hash')) p.textContent = 'Computing hashes…'
      else if (m.includes('cluster')) p.textContent = 'Clustering…'
      else if (m.includes('complete')) p.textContent = 'Complete!'
    }
    if (data.status === AnalysisStatus.DONE) {
      enginePollRef.current?.stop()
      analysisComplete = true
      analysisInProgress = false
      resetSimUI()
      loadSimResults()
    }
  })

  const capturedSid = sessionId
  engine.sim.getResult(sessionId).then(data => {
    if (capturedSid !== sessionId) return
    if (data.status === AnalysisStatus.DONE) {
      groups = (data.groups as SimilarityGroup[]) || []
      ungrouped = (data.ungrouped as { path: string }[]) || []
      stats = (data.stats as Record<string, number>) || {}
      // Restore previous selection where possible; select all when none match.
      restoreSelectionOrSelectAll(groups)
      analysisComplete = true
      renderResults()
      showStage('results')
      resetSimUI()
    }
  }).catch((err: unknown) => { showError(err, 'Failed to load existing results. Please try refreshing the page.') })

  registerCleanup(() => {
    if (analysisInProgress) {
      engine.sim.cancelAnalysis(sessionId).catch(console.error)
    }
    enginePollRef.current?.stop(); unsubProgress(); clearTimeout(reclusterTimer); engineRestartUnsub?.(); cleanups.forEach(fn => fn()); _cleanupDelegated()
  })
}

function resetSimUI(): void {
  const btn = $('#btnStartSim') as HTMLButtonElement | null
  if (btn) { btn.disabled = false; btn.textContent = 'Start Analysis'; btn.classList.remove('hidden') }
  const cancelBtn = $('#btnCancelSim') as HTMLElement | null
  if (cancelBtn) { cancelBtn.classList.add('hidden'); (cancelBtn as HTMLButtonElement).disabled = false; cancelBtn.textContent = 'Cancel Analysis' }
  const slider = $('#simThresh') as HTMLInputElement | null; if (slider) slider.disabled = false
  const minInp = $('#simMin') as HTMLInputElement | null; if (minInp) minInp.disabled = false
  $('#simBefore')?.classList.remove('hidden')
  $('#simRunning')?.classList.add('hidden')
}

function restoreSelectionOrSelectAll(
  nextGroups: SimilarityGroup[],
  previousSelection: Set<string> = selectedGroupIds,
  preserveEmptySelection = false
): void {
  const prevSelected = new Set(previousSelection)
  selectedGroupIds.clear()
  nextGroups.forEach(g => { if (prevSelected.has(String(g.id))) selectedGroupIds.add(String(g.id)) })
  if (preserveEmptySelection && prevSelected.size === 0) return
  if (selectedGroupIds.size === 0) nextGroups.forEach(g => selectedGroupIds.add(String(g.id)))
}

// ── Internal ──

function showStage(name: 'progress' | 'results'): void {
  $('#simProgress')?.classList.toggle('active', name === 'progress')
  $('#simResults')?.classList.toggle('active', name === 'results')
}

async function loadSimResults(): Promise<void> {
  if (loadingResults) return
  loadingResults = true
  try {
    const d = await engine.sim.getResult(sessionId)
    if (d.status === AnalysisStatus.DONE) {
      groups = (d.groups as SimilarityGroup[]) || []
      ungrouped = (d.ungrouped as { path: string }[]) || []
      stats = (d.stats as Record<string, number>) || {}
    }
    restoreSelectionOrSelectAll(groups)
    renderResults()
    showStage('results')
    toast('Analysis complete!', 'success')
  } catch (err: unknown) {
    showError(err, 'Analysis completed but failed to load results.')
  } finally {
    loadingResults = false
  }
}

function startAnalysis(): void {
  const { threshold, minGroup } = getSimilarityParams({ syncInputs: true })
  analysisComplete = false
  analysisInProgress = true
  const slider = $('#simThresh') as HTMLInputElement | null; if (slider) slider.disabled = true
  const minInp = $('#simMin') as HTMLInputElement | null; if (minInp) minInp.disabled = true
  const btn = $('#btnStartSim') as HTMLButtonElement | null;
  if (btn) { btn.disabled = true; btn.textContent = 'Analyzing...'; btn.classList.add('hidden') }
  const cancelBtn = $('#btnCancelSim') as HTMLElement | null
  if (cancelBtn) cancelBtn.classList.remove('hidden')
  showStage('progress')
  $('#simBefore')?.classList.add('hidden')
  $('#simRunning')?.classList.remove('hidden')
  engine.sim.analyze(sessionId, { threshold, min_group_size: minGroup })
    .then(() => {
      enginePollRef.current = createPollLoop(
        () => engine.sim.getResult(sessionId),
        (data) => {
          if (analysisComplete) { return true }
          if (data.status === AnalysisStatus.DONE) {
            analysisComplete = true
            analysisInProgress = false
            resetSimUI()
            loadSimResults()
            return true
          }
          if (data.status === AnalysisStatus.FAILED) {
            analysisInProgress = false
            showError(data.error, 'Analysis failed.')
            resetSimUI()
            return true
          }
          return false
        },
        MAX_POLL_RETRIES_SIM,
        POLL_INTERVAL_SIM,
        (err: unknown) => { showError(err, 'Lost connection while checking progress.') },
        () => {
          analysisInProgress = false
          showError(new Error('Analysis timed out'), 'Analysis timed out. Please try again.')
          resetSimUI()
        },
      )
      enginePollRef.current.start(0)
    })
    .catch((err: unknown) => {
      analysisInProgress = false
      showError(err, 'Analysis failed to start.')
      resetSimUI()
    })
}

function recluster(): void {
  if (!groups.length) {
    if (analysisInProgress) {
      toast('Analysis is in progress. Please wait before adjusting threshold.', 'warning')
    } else {
      toast('Wait for initial analysis to complete before adjusting threshold.', 'warning')
    }
    return
  }
  const { threshold, minGroup } = getSimilarityParams({ syncInputs: true })
  if (threshold === lastThreshold && minGroup === lastMinGroup) return
  lastThreshold = threshold
  lastMinGroup = minGroup
  analysisInProgress = true
  enginePollRef.current?.stop()
  showStage('progress')
  $('#simBefore')?.classList.add('hidden')
  $('#btnCancelSim')?.classList.remove('hidden')
  $('#simRunning')?.classList.remove('hidden')
  const phase = $('#phaseLabel'); if (phase) phase.textContent = 'Reclustering…'
  const file = $('#simFile'); if (file) file.textContent = 'Adjusting groups…'
  const fill = $('#simFill'); if (fill) { (fill as HTMLElement).style.width = '100%'; fill.classList.add('progress__fill--indeterminate') }

  // Save user's group selection before recluster so we can restore it after rerender
  const prevSelected = new Set(selectedGroupIds)

  engine.sim.recluster(sessionId, threshold, minGroup).then(data => {
    if (data.status === 'started') {
      enginePollRef.current = createPollLoop(
        () => engine.sim.getResult(sessionId),
        (d) => {
          if (d.status === AnalysisStatus.DONE) {
            analysisComplete = true
            analysisInProgress = false
            // Restore previous selection for groups that still exist after recluster
            groups = (d.groups as SimilarityGroup[]) || []
            restoreSelectionOrSelectAll(groups, prevSelected, hasUserTouchedSelection)
            renderResults(); showStage('results')
            return true
          }
          if (d.status === AnalysisStatus.FAILED) {
            analysisInProgress = false
            showError(d.error, 'Recluster failed. Please try adjusting the threshold.')
            showStage('results')
            return true
          }
          return false
        },
        MAX_POLL_RETRIES_SIM,
        POLL_INTERVAL_SIM,
        (err: unknown) => { showError(err, 'Lost connection while checking progress.') },
        () => {
          analysisInProgress = false
          showError(new Error('Recluster timed out'), 'Recluster timed out. Please try adjusting the threshold.')
          showStage('results')
        },
      )
      enginePollRef.current.start(0)
    } else {
      analysisInProgress = false
      showError(new Error('Recluster returned unexpected status'), 'Recluster did not start. Please try adjusting the threshold.')
      showStage('results')
      resetSimUI()
    }
  }).catch((err: unknown) => {
    analysisInProgress = false
    showError(err, 'Recluster failed. Please try adjusting the threshold.')
    showStage('results')
    resetSimUI()
  })
}

function renderResults(): void {
  setText('sTotal', stats.total || 0); setText('sGrouped', stats.grouped || 0)
  setText('sUngrouped', stats.ungrouped || 0); setText('sGroups', stats.num_groups || 0)

  const grid = $('#simGrid'); if (!grid) return; grid.innerHTML = ''
  const fragment = document.createDocumentFragment()
  groups.forEach(g => {
    const card = document.createElement('div'); card.className = 'sim-group-card'; card.dataset.groupId = String(g.id); card.setAttribute('tabindex', '0'); card.setAttribute('role', 'button'); card.setAttribute('aria-expanded', 'false'); card.setAttribute('aria-label', `Similarity group: ${g.label || `Group_${g.id}`}, ${g.count} photos`)
    const thumb = typeof g.thumbnail_base64 === 'string' && isValidBase64(g.thumbnail_base64) ? g.thumbnail_base64 : null
    card.innerHTML = `
        <div class="sim-group-card__header">
          <input type="checkbox" class="sim-group-checkbox" data-group-id="${esc(String(g.id))}" ${selectedGroupIds.has(String(g.id)) ? 'checked' : ''} aria-label="Select ${esc(String(g.label || `Group_${g.id}`))} (${g.count} photos)">
          <span class="sim-group-card__label">${esc(String(g.label || `Group_${g.id}`))}</span>
          <span class="sim-group-card__count">${g.count} photos</span>
        </div>
      <div class="sim-group-card__thumbs">
        ${thumb ? `<img class="sim-group-card__thumb-img" src="data:image/jpeg;base64,${thumb}" alt="">` : ''}
        ${g.images.slice(thumb ? 1 : 0, 4).map(img => {
          const f = (img.path || '').replace(/\\/g, '/').split('/').pop() || ''
          return `<div class="sim-group-card__thumb${img.representative ? ' sim-group-card__thumb--rep' : ''}" title="${esc(f)}">${esc(f)}</div>`
        }).join('')}
        ${g.count > 4 ? `<div class="sim-group-card__thumb">+${g.count - 4} more</div>` : ''}
      </div>
      <div class="sim-group-card__paths">${g.images.map(img =>
        `<div class="sim-group-card__path${img.representative ? ' sim-group-card__path--rep' : ''}">${img.representative ? '* ' : '  '}${esc(img.path)}</div>`
      ).join('')}</div>`;
    fragment.appendChild(card)
  })
  grid.appendChild(fragment)

  if (!groups.length) {
    grid.innerHTML = `<div class="empty-state"><div class="empty-state__icon">&#128269;</div><div class="empty-state__text">${stats.total === 0 ? 'Add photos to this session first.' : 'No similar images found in this session. Try lowering the threshold to find more matches.'}</div></div>`
    _cleanupDelegated()
    const ung = $('#simUngList'); if (!ung) return; ung.innerHTML = ungrouped.map(u => `<div class="sim-ungrouped-item">${esc(u.path)}</div>`).join('')
    const cnt = $('#simUngCnt'); if (cnt) cnt.textContent = String(ungrouped.length)
    return
  }

  _cleanupDelegated()
  _delegatedCleanups.push(on(grid, 'click', '.sim-group-card', (el, e) => {
    if ((e.target as HTMLElement).tagName !== 'INPUT') {
      el.classList.toggle('sim-group-card--expanded')
      el.setAttribute('aria-expanded', el.classList.contains('sim-group-card--expanded') ? 'true' : 'false')
    }
  }))
  _delegatedCleanups.push(on(grid, 'keydown', '.sim-group-card', (el, ev) => {
    const ke = ev as KeyboardEvent
    if (ke.key === 'Enter' || ke.key === ' ') { ke.preventDefault(); if ((ev.target as HTMLElement).tagName !== 'INPUT') {
      el.classList.toggle('sim-group-card--expanded')
      el.setAttribute('aria-expanded', el.classList.contains('sim-group-card--expanded') ? 'true' : 'false')
    }}
  }))
  _delegatedCleanups.push(on(grid, 'change', '.sim-group-checkbox', (el) => {
    hasUserTouchedSelection = true
    const cb = el as HTMLInputElement
    const gid = cb.dataset.groupId
    if (gid) {
      if (cb.checked) selectedGroupIds.add(gid)
      else selectedGroupIds.delete(gid)
    }
  }))

  const ung = $('#simUngList'); if (!ung) return; ung.innerHTML = ungrouped.map(u => `<div class="sim-ungrouped-item">${esc(u.path)}</div>`).join('')
  const cnt = $('#simUngCnt'); if (cnt) cnt.textContent = String(ungrouped.length)
}

function setAllOpts(v: boolean): void {
  hasUserTouchedSelection = true
  document.querySelectorAll<HTMLInputElement>('.sim-global-opt').forEach(cb => { cb.checked = v })
  document.querySelectorAll<HTMLInputElement>('.sim-group-checkbox').forEach(cb => {
    cb.checked = v
    const gid = cb.dataset.groupId
    if (gid) {
      if (v) selectedGroupIds.add(gid)
      else selectedGroupIds.delete(gid)
    }
  })
}

async function executeWb(): Promise<void> {
  const selectedGroups = groups.filter(g => selectedGroupIds.has(String(g.id)))
  if (selectedGroups.length === 0) {
    toast('Select at least one group for writeback.', 'warning')
    return
  }
  const btn = $('#btnExecWb') as HTMLButtonElement | null
  if (btn) btn.disabled = true
  try {
    const options: Record<string, boolean> = {}
    ALLOWED_OPTIONS.forEach(opt => {
      const cb = document.querySelector(`.sim-global-opt[data-option="${opt}"]`) as HTMLInputElement | null
      options[opt] = cb?.checked ?? false
    })
    const groupIds = selectedGroups.map(g => g.id)
    const preview = await engine.sim.previewWriteback(sessionId, groupIds, options)
    const totalAffected = Number(preview.total_affected || 0)
    const warnings = Array.isArray(preview.warnings) ? preview.warnings.length : 0
    const action = options.writeIPTC
      ? `write XMP keywords for ${totalAffected} photos`
      : `generate a writeback report for ${totalAffected} photos without modifying XMP`
    const warningText = warnings ? `\n\nWarnings: ${warnings} file(s) may be missing or unavailable.` : ''
    if (!await dialog(`Preview complete: Gather will ${action} across ${selectedGroups.length} groups.${warningText}\n\nContinue?`, options.writeIPTC ? 'Write Metadata' : 'Generate Report')) { toast('Writeback cancelled.', 'info'); return }
    const result = await engine.sim.writeback(sessionId, groupIds, options)
    const r = $('#simReport'); if (r) r.textContent = (result.report as string) || 'Done.'
    openSimModal()
    toast(`Writeback: ${result.total_affected} images affected`, 'success')
  } catch (err: unknown) { showError(err, `Writeback failed: ${err instanceof Error ? err.message : 'unknown error'}`) }
  finally { if (btn) btn.disabled = false }
}

function getSimilarityParams({ syncInputs = false } = {}): { threshold: number; minGroup: number } {
  const thresholdInput = $('#simThresh') as HTMLInputElement | null
  const minGroupInput = $('#simMin') as HTMLInputElement | null
  const threshold = clampInteger(thresholdInput?.value ?? THRESHOLD_DEFAULT, THRESHOLD_DEFAULT, THRESHOLD_MIN, THRESHOLD_MAX)
  const minGroup = clampInteger(minGroupInput?.value ?? MIN_GROUP_DEFAULT, MIN_GROUP_DEFAULT, MIN_GROUP_MIN, MIN_GROUP_MAX)

  if (syncInputs) {
    if (thresholdInput) thresholdInput.value = String(threshold)
    if (minGroupInput) minGroupInput.value = String(minGroup)
    setText('preThresh', threshold)
    setText('preMin', minGroup)
  }

  return { threshold, minGroup }
}

function openSimModal(): void {
  const modal = $('#simModal')
  if (!modal) return
  simModalPreviousFocus = document.activeElement as HTMLElement | null
  modal.classList.add('active')
  ;($('#btnCloseModal') as HTMLButtonElement | null)?.focus()
}

function closeSimModal(): void {
  $('#simModal')?.classList.remove('active')
  simModalPreviousFocus?.focus()
  simModalPreviousFocus = null
}
