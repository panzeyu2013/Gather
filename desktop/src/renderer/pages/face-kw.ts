// src/renderer/pages/face-kw.ts
// Face Keywording — 5-step wizard

import { engine, showError } from '../api'
import { clearSessionId } from '../app'
import { dialog } from '../components/dialog'
import { $, $$, esc, on, setText } from '../components/dom'
import { createProgressRenderer } from '../components/progress'
import { toast } from '../components/toast'
import { navigate, registerCleanup } from '../router'
import { createPollLoop } from '../utils/poll'
import { isValidBase64 } from '../utils/validation'
import { createEngineRestartHandler, type EngineRestartHandler } from '../utils/engine-restart'
import type { ClusterData } from '@gather/shared'
import { AnalysisStatus } from '@gather/shared'
import {
  TOAST_DURATION_LONG,
  TOAST_DURATION_SHORT,
  MAX_POLL_RETRIES_FKW,
  POLL_INTERVAL_FKW,
} from '@gather/shared'

// ── State ──
let sessionId = ''
let sessionName = ''
let step = 1
let clusters: ClusterData[] = []
let noise: unknown[] = []
let bindings: Record<number, { role_name: string; keywords: string[] }> = {}
let skipped: Record<number, boolean> = {}
let selectedCluster: number | null = null
let previewData: Record<string, unknown>[] = []
let currentTags: string[] = []
let analysisDone = false
let analysisInProgress = false
let mergeMode = false
let mergeSource: number | null = null
let cleanupFns: (() => void)[] = []

let engineRestartUnsub: (() => void) | null = null
let enginePollRef: EngineRestartHandler['pollRef'] = { current: null }

function hydrateClusterState(nextClusters: ClusterData[]): void {
  clusters = nextClusters
  bindings = {}
  skipped = {}
  for (const cluster of nextClusters) {
    if (cluster.binding) {
      bindings[cluster.cluster_id] = {
        role_name: cluster.binding.role_name,
        keywords: [...cluster.binding.keywords],
      }
    }
    if (cluster.status === 'skipped') {
      skipped[cluster.cluster_id] = true
    }
  }
}

function resetCancelUI(): void {
  const cancelBtn = $('#btnFkwCancel') as HTMLButtonElement | null
  if (cancelBtn) { cancelBtn.classList.add('hidden'); cancelBtn.disabled = false; cancelBtn.textContent = 'Cancel Analysis' }
  const startBtn = $('#btnFkwStart') as HTMLButtonElement | null
  if (startBtn) { startBtn.classList.remove('hidden'); startBtn.disabled = false }
}

function resetState(): void {
  step = 1; clusters = []; noise = []; bindings = {}; skipped = {}
  selectedCluster = null; previewData = []; currentTags = []; analysisDone = false
  analysisInProgress = false
  mergeMode = false; mergeSource = null; enginePollRef.current?.stop()
}

// ── Stepper Config ──
const STEPS = [
  { num: 1, label: 'Analyze', desc: 'Analyze faces' },
  { num: 2, label: 'Clusters', desc: 'Review groups' },
  { num: 3, label: 'Bind', desc: 'Assign roles & keywords' },
  { num: 4, label: 'Preview', desc: 'Review assignments' },
  { num: 5, label: 'Save to Files', desc: 'Write XMP metadata' },
]

function stepperHtml(): string {
  return STEPS.map(s => `
    <div class="stepper-step${s.num === 1 ? ' stepper-step--active' : ''}" data-step="${s.num}" role="button" tabindex="0" aria-label="Step ${s.num}: ${s.label} - ${s.desc}"${s.num === 1 ? ' aria-current="step"' : ''}>
      <div class="stepper-step__indicator">${s.num}</div>
      <div class="stepper-step__body"><div class="stepper-step__label">${s.label}</div><div class="stepper-step__desc">${s.desc}</div></div>
    </div>`).join('')
}

function updateStepper(n: number): void {
  if (n === 3 && !selectedCluster) {
    toast('Select a cluster first.', 'warning')
    updateStepper(2)
    return
  }
  step = n
  $$('.fkw-panel').forEach(p => p.classList.remove('active'))
  $(`.fkw-panel[data-panel="${n}"]`)?.classList.add('active')
  $$('#fkwStepper .stepper-step').forEach(el => {
    const sn = parseInt((el as HTMLElement).dataset.step || '0')
    el.classList.toggle('stepper-step--active', sn === n)
    el.classList.toggle('stepper-step--done', sn < n)
    if (sn === n) el.setAttribute('aria-current', 'step')
    else el.removeAttribute('aria-current')
  })
  if (n === 2 && analysisDone) renderClusters()
  if (n === 3) loadBind()
  if (n === 4) loadPreview()
}

// ── Render ──
export async function renderFaceKeywording(sid: string): Promise<string> {
  sessionId = sid; resetState()
  let sessionSource = 'unknown'
  // 获取 session 名称
  try {
    const sessions = await engine.session.list()
    const s = sessions.find(s => s.id === sid)
    if (s) {
      sessionName = s.name || ''
      sessionSource = s.import_source || 'unknown'
    }
  } catch (err: unknown) { console.error('Failed to load session name', err); sessionName = '' }

  const guidanceText = sessionSource === 'capture_one' 
    ? '1. Select images in C1<br>2. Image → Load Metadata<br>3. Verify keywords appear'
    : 'XMP sidecars were written next to the selected files. Import or refresh metadata in your photo manager.'

  return `<div>
<div class="section-header" style="display:flex;align-items:center;justify-content:space-between;margin-bottom:1.5rem">
  <div style="display:flex;align-items:center;gap:0.75rem">
    <a class="btn btn--secondary btn--sm" id="btnFkwDash">← Dashboard</a>
    <h1>Face Keywording</h1>
    <span style="font-size:0.85rem;color:var(--text-muted)">${esc(sessionName || sid.slice(0, 8) + '…')}</span>
  </div>
  <button class="btn btn--danger btn--sm" id="btnFkwDel">Delete Session</button>
</div>

<div class="wizard__stepper" id="fkwStepper" style="display:flex;gap:0.5rem;margin-bottom:1.5rem;flex-wrap:wrap">
  ${stepperHtml()}
</div>

<!-- Panel 1: Import & Analyze -->
<div class="fkw-panel active" data-panel="1">
  <div class="fkw-session-info">
    <div class="fkw-stat"><div class="fkw-stat__value" id="fkwStatPhotos">-</div><div class="fkw-stat__label">Photos</div></div>
    <div class="fkw-stat"><div class="fkw-stat__value" id="fkwStatFaces">-</div><div class="fkw-stat__label">Faces Found</div></div>
    <div class="fkw-stat"><div class="fkw-stat__value" id="fkwStatClusters">-</div><div class="fkw-stat__label">Clusters</div></div>
  </div>
  <button class="btn btn--primary btn--lg" id="btnFkwStart">Start Face Analysis</button>
  <button class="btn btn--warning btn--lg hidden" id="btnFkwCancel">Cancel Analysis</button>
  <div class="fkw-progress-wrap hidden" id="fkwProgWrap">
    <div class="progress" role="progressbar" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100" aria-label="Analysis progress"><div class="progress__fill" style="width:0%"></div></div>
    <div class="fkw-progress-text" id="fkwProgText" aria-live="polite">Preparing…</div>
  </div>
  <div class="fkw-nav"><div></div><button class="btn btn--primary" id="btnToStep2" disabled>Next: Clusters →</button></div>
</div>

<!-- Panel 2: Clusters -->
<div class="fkw-panel" data-panel="2">
  <div class="fkw-filter-bar" id="fkwFilter">
    <button class="fkw-filter-btn active" data-filter="all" aria-pressed="true">All</button>
    <button class="fkw-filter-btn" data-filter="unbound" aria-pressed="false">Unnamed</button>
    <button class="fkw-filter-btn" data-filter="bound" aria-pressed="false">Named</button>
    <button class="fkw-filter-btn" data-filter="skipped" aria-pressed="false">Skipped</button>
  </div>
  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:0.75rem">
    <span style="font-size:0.82rem;color:var(--text-muted)">Sorted by member count ↓ · Click to select & bind.</span>
    <div style="display:flex;gap:0.5rem">
      <button class="btn btn--secondary btn--sm hidden" id="btnMergeSel">Merge</button>
      <button class="btn btn--secondary btn--sm" id="btnMergeToggle">Merge Mode</button>
    </div>
  </div>
  <div class="face-grid" id="fkwClusterGrid"><div class="empty-state"><div class="spinner"></div><div class="empty-state__text mt-1">Loading…</div></div></div>
  <div class="fkw-nav"><button class="btn btn--secondary" id="btnToStep1">← Back</button><button class="btn btn--primary" id="btnToStep3" disabled>Next: Bind →</button></div>
</div>

<!-- Panel 3: Bind -->
<div class="fkw-panel" data-panel="3">
  <p id="fkwBindTitle">Select a cluster to begin.</p>
  <div class="fkw-bind-layout">
    <div>
      <img class="fkw-face-preview" id="fkwFacePrev" src="" alt="">
      <div style="margin-top:0.5rem;font-size:0.82rem;color:var(--text-muted)"><span id="fkwMemCnt">0</span> members</div>
      <div class="fkw-member-list" id="fkwMemList"></div>
    </div>
    <div>
      <label style="font-weight:600;font-size:0.9rem" for="fkw-role">Role Name</label>
      <input type="text" id="fkw-role" placeholder="e.g. Alice, Bob…" style="width:100%;display:block;margin-top:0.25rem;padding:0.5rem 0.75rem;background:var(--bg);border:1px solid var(--border);border-radius:var(--radius);color:var(--text);font-size:0.9rem">
      <label style="font-weight:600;font-size:0.9rem;margin-top:1rem" for="fkw-keywords">Keywords</label>
      <div class="fkw-tag-editor" id="fkwTagEditor"><input class="fkw-tag-input" id="fkw-keywords" placeholder="Type + Enter…"></div>
      <div style="margin-top:0.25rem;font-size:0.75rem;color:var(--text-dim)">Enter or comma to add</div>
      <div style="display:flex;gap:0.75rem;margin-top:1.5rem">
        <button class="btn btn--secondary" id="btnSkip">Skip</button>
        <button class="btn btn--primary" id="btnBindSave">Save & Next</button>
      </div>
    </div>
  </div>
  <div class="fkw-nav"><button class="btn btn--secondary" id="btnToStep2From3">← Clusters</button><button class="btn btn--primary" id="btnToStep4">Preview →</button></div>
</div>

<!-- Panel 4: Preview -->
<div class="fkw-panel" data-panel="4">
  <div id="fkwPrevStats" style="margin-bottom:1rem;font-size:0.88rem;color:var(--text-muted)"></div>
  <div class="fkw-table-wrap"><table class="fkw-table" id="fkwPrevTable"><thead><tr><th>Photo</th><th>Keywords</th><th>Sources</th></tr></thead><tbody></tbody></table></div>
  <div class="fkw-nav"><button class="btn btn--secondary" id="btnToStep3From4">← Bind</button><button class="btn btn--primary btn--lg" id="btnWb">Write XMP Metadata</button></div>
</div>

<!-- Panel 5: Writeback -->
<div class="fkw-panel" data-panel="5">
  <div class="fkw-progress-wrap" id="fkwWbWrap"><div class="progress" role="progressbar" aria-valuenow="0" aria-valuemin="0" aria-valuemax="100" aria-label="Writeback progress"><div class="progress__fill" style="width:0%"></div></div><div class="fkw-progress-text" id="fkwWbText">Starting…</div></div>
  <div class="fkw-result-grid hidden" id="fkwWbResults">
    <div class="fkw-result-card success"><div class="fkw-result-card__value" id="fkwWrWritten">-</div><div class="fkw-stat__label">Written</div></div>
    <div class="fkw-result-card failure"><div class="fkw-result-card__value" id="fkwWrFailed">-</div><div class="fkw-stat__label">Failed</div></div>
    <div class="fkw-result-card"><div class="fkw-result-card__value" id="fkwWrSkipped">-</div><div class="fkw-stat__label">Skipped</div></div>
  </div>
  <div class="fkw-guidance hidden" id="fkwGuide">
    <div class="fkw-guidance__title">Next: Reload Metadata in Capture One</div>
    <div class="fkw-guidance__steps">${guidanceText}</div>
  </div>
  <div style="margin-top:1.5rem;display:flex;gap:0.75rem;flex-wrap:wrap">
    <button class="btn btn--success btn--lg hidden" id="btnConfirmSync">Confirm Sync</button>
    <button class="btn btn--secondary btn--lg hidden" id="btnCleanup">Clean Up XMP</button>
  </div>
  <button class="btn btn--warning btn--lg hidden" id="btnWbRetry" style="margin-top:0.5rem">Retry failed items</button>
  <div class="fkw-nav"><button class="btn btn--secondary" id="btnToStep4From5">← Preview</button><div></div></div>
</div>
</div>`
}

// ── Setup ──
export function setupFaceKeywording(): void {
  const c = document.getElementById('content')
  if (!c) { console.error('[face-kw] content element not found'); return }
  cleanupFns = []

  // Clear module-level state for fresh session navigation
  bindings = {}
  skipped = {}

  const restartHandler = createEngineRestartHandler(() => {
    analysisInProgress = false
    analysisDone = false
    clusters = []; noise = []; bindings = {}; skipped = {}
    selectedCluster = null; previewData = []; currentTags = []
    mergeMode = false; mergeSource = null
    const startBtn = $('#btnFkwStart') as HTMLButtonElement
    if (startBtn) startBtn.disabled = false
    resetCancelUI()
    renderClusters()
    updateStats()
  })
  engineRestartUnsub = restartHandler.unsub
  enginePollRef = restartHandler.pollRef

  // Navigation
  cleanupFns.push(on(c, 'click', '#btnFkwDash', () => navigate('dashboard')))
  cleanupFns.push(on(c, 'click', '#btnFkwDel', async () => { if (!await dialog('Delete session?', 'Delete')) return; try { await engine.session.delete(sessionId); clearSessionId(); navigate('dashboard') } catch (err: unknown) { showError(err, 'Delete failed. The session may have already been removed.') } }))
  cleanupFns.push(on(c, 'click', '#btnToStep1', () => updateStepper(1)))
  cleanupFns.push(on(c, 'click', '#btnToStep2', () => { if (step === 1 && !analysisDone) { toast('Run analysis first.', 'warning'); return } updateStepper(2) }))
  cleanupFns.push(on(c, 'click', '#btnToStep3', () => { if (!selectedCluster) { toast('Select a cluster first.', 'warning'); return } updateStepper(3) }))
  cleanupFns.push(on(c, 'click', '#btnToStep4', () => updateStepper(4)))
  cleanupFns.push(on(c, 'click', '#btnToStep2From3', () => updateStepper(2)))
  cleanupFns.push(on(c, 'click', '#btnToStep3From4', () => updateStepper(3)))
  cleanupFns.push(on(c, 'click', '#btnToStep4From5', () => updateStepper(4)))

  cleanupFns.push(on(c, 'click', '#fkwStepper .stepper-step', function (this: HTMLElement) {
    const n = parseInt(this.dataset.step || '0')
    if (!n) return
    if (n === 3 && !selectedCluster) {
      toast('Select a cluster first.', 'warning')
      updateStepper(2)
      return
    }
    updateStepper(n)
  }))

  cleanupFns.push(on(c, 'keydown', '#fkwStepper .stepper-step', (el, e) => {
    const ke = e as KeyboardEvent
    if (ke.key === 'Enter' || ke.key === ' ') {
      ke.preventDefault()
      const n = parseInt((el as HTMLElement).dataset.step || '0')
      if (!n) return
      if (n === 3 && !selectedCluster) {
        toast('Select a cluster first.', 'warning')
        updateStepper(2)
        return
      }
      updateStepper(n)
    }
  }))

  cleanupFns.push(on(c, 'click', '#fkwFilter .fkw-filter-btn', (el, e) => {
    e.preventDefault()
    $$('#fkwFilter .fkw-filter-btn').forEach(b => { b.classList.remove('active'); b.setAttribute('aria-pressed', 'false') })
    el.classList.add('active'); el.setAttribute('aria-pressed', 'true')
    renderClusters()
  }))

  // Analysis
  cleanupFns.push(on(c, 'click', '#btnFkwStart', async function (this: HTMLButtonElement) {
    this.disabled = true; const w = $('#fkwProgWrap'); if (w) w.classList.remove('hidden')
    $('#btnFkwCancel')?.classList.remove('hidden'); ($('#btnFkwStart') as HTMLButtonElement).classList.add('hidden')
    analysisInProgress = true
    try { await engine.fkw.analyze(sessionId); startPollProgress() } catch (err: unknown) { showError(err, 'Failed to start analysis.'); if (w) w.classList.add('hidden'); this.disabled = false; analysisInProgress = false; resetCancelUI() }
  }))
  cleanupFns.push(on(c, 'click', '#btnFkwCancel', async (el) => {
    const btn = el as HTMLButtonElement
    btn.disabled = true
    btn.textContent = 'Cancelling…'
    try {
      await engine.fkw.cancelAnalysis(sessionId)
      toast('Analysis cancelled.', 'warning')
      resetCancelUI()
    } catch (err: unknown) {
      showError(err, 'Cancel failed. Please try again.')
      btn.disabled = false
      btn.textContent = 'Cancel Analysis'
      resetCancelUI()
    }
  }))

  // Cluster card event delegation
  const clusterGrid = $('#fkwClusterGrid')
  if (clusterGrid) {
    cleanupFns.push(on(clusterGrid, 'click', '.face-cluster-card', (el) => {
      if (el.dataset.cid) handleClusterClick(Number(el.dataset.cid))
    }))
    cleanupFns.push(on(clusterGrid, 'keydown', '.face-cluster-card', (el, ev) => {
      const ke = ev as KeyboardEvent
      if (ke.key === 'Enter' || ke.key === ' ') {
        ke.preventDefault(); if (el.dataset.cid) handleClusterClick(Number(el.dataset.cid))
      }
    }))
  }

  // Merge
  cleanupFns.push(on(c, 'click', '#btnMergeToggle', function (this: HTMLButtonElement) {
    mergeMode = !mergeMode; this.textContent = mergeMode ? 'Merge: Select Source' : 'Merge Mode'
    this.classList.toggle('btn--primary', mergeMode); mergeSource = null; $('#btnMergeSel')?.classList.add('hidden')
    if (!mergeMode) renderClusters()
  }))
  cleanupFns.push(on(c, 'click', '#btnMergeSel', async () => {
    if (!mergeSource || !selectedCluster) { toast('Select source and target clusters.', 'warning'); return }
    if (mergeSource === selectedCluster) { toast('Cannot merge into itself.', 'warning'); return }
    try {
      const srcLabel = clusters.find(c => c.cluster_id === mergeSource)?.label || `Person-${mergeSource}`
      const tgtLabel = clusters.find(c => c.cluster_id === selectedCluster)?.label || `Person-${selectedCluster}`
      if (!await dialog(`Merge "${srcLabel}" into "${tgtLabel}"? This cannot be undone.`, 'Merge')) return
      await engine.fkw.merge(sessionId, mergeSource, selectedCluster)
      toast('Merged!', 'success'); mergeMode = false; mergeSource = null
      const mergeBtn = $('#btnMergeToggle')
      if (mergeBtn) { mergeBtn.textContent = 'Merge Mode'; mergeBtn.classList.remove('btn--primary') }
      $('#btnMergeSel')?.classList.add('hidden')
      const data = await engine.fkw.getClusters(sessionId)
      clusters = (data.clusters as ClusterData[]) || []; renderClusters()
    } catch (err: unknown) { showError(err, 'Merge failed. Please try again or refresh the page.') }
  }))

  // Bind
  cleanupFns.push(on(c, 'keydown', '#fkw-keywords', (el, e) => {
    const ke = e as KeyboardEvent
    const input = el as HTMLInputElement
    if (ke.key === 'Enter' || ke.key === ',') { ke.preventDefault(); addTag(input.value); input.value = '' }
  }))
  cleanupFns.push(on(c, 'click', '#fkwTagEditor', () => { $('#fkw-keywords')?.focus() }))
  cleanupFns.push(on(c, 'keydown', '#fkwTagEditor', (el, e) => {
    const ke = e as KeyboardEvent
    if (ke.key === 'Enter' || ke.key === ' ') {
      const target = (e.target as HTMLElement).closest<HTMLElement>('[data-action="remove-tag"]')
      if (target && target.dataset.tag) {
        ke.preventDefault(); ke.stopPropagation()
        const tag = target.dataset.tag
        currentTags = currentTags.filter(t => t !== tag)
        renderTags(currentTags)
      }
    }
  }))
  cleanupFns.push(on(c, 'click', '#btnBindSave', async function (this: HTMLButtonElement) {
    const cid = selectedCluster; if (!cid) return
    const role = (($('#fkw-role') as HTMLInputElement)?.value || '').trim()
    if (!role) { toast('Enter a role name.', 'warning'); return }
    if (!currentTags.length) { toast('Add at least one keyword.', 'warning'); return }
    this.disabled = true
    try {
      await engine.fkw.bind(sessionId, cid, role, currentTags.slice())
      bindings[cid] = { role_name: role, keywords: currentTags.slice() }; delete skipped[cid]
      advanceToNext()
      toast(`Bound: ${role}`, 'success', TOAST_DURATION_LONG)
    } catch (err: unknown) { showError(err, 'Bind failed. Please try again.') }
    this.disabled = false
  }))
  cleanupFns.push(on(c, 'click', '#btnSkip', async () => {
    const cid = selectedCluster; if (!cid) return
    try {
      await engine.fkw.unbind(sessionId, cid)
      delete bindings[cid]; skipped[cid] = true
      advanceToNext()
      toast('Skipped.', 'info', TOAST_DURATION_LONG)
    } catch (err: unknown) { showError(err, 'Skip failed. Please try again.') }
  }))

  // Remove member
  const removeHandler = async (e: Event) => {
    const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-remove]'); if (!btn) return
    const pid = btn.dataset.remove; if (!pid) return
    const cid = selectedCluster; if (!cid || !pid) return
    const cl = clusters.find(c => c.cluster_id === cid)
    const member = cl?.members?.find(m => m.photo_id === pid)
    const filename = member?.filename || pid
    if (!await dialog(`Remove "${filename}" from cluster?`, 'Remove')) return
    try {
      await engine.fkw.removeMember(sessionId, cid, pid)
      const cl = clusters.find(c => c.cluster_id === cid)
      if (cl) { const m = cl.members || []; cl.members = m.filter(x => x.photo_id !== pid); cl.size = cl.members.length }
      loadBind()
      toast('Removed from cluster.', 'info', TOAST_DURATION_SHORT)
    } catch (err: unknown) { showError(err, 'Remove failed. Please try again.') }
  }
  c.addEventListener('click', removeHandler); cleanupFns.push(() => c.removeEventListener('click', removeHandler))

  // Writeback
  cleanupFns.push(on(c, 'click', '#btnWb', async function (this: HTMLButtonElement) {
    const photoCount = previewData.length || 0
    if (!await dialog(`This will permanently write keywords to XMP sidecar files for ${photoCount || 'an unknown number of'} photos. This action cannot be undone. Continue?`, 'Write Keywords')) return
    this.disabled = true
    try {
      updateStepper(5)
      await doWriteback()
    } finally {
      this.disabled = false
    }
  }))
  cleanupFns.push(on(c, 'click', '#btnWbRetry', async function (this: HTMLButtonElement) {
    this.disabled = true; this.textContent = 'Retrying…'
    await doWriteback()
    this.disabled = false; this.textContent = 'Retry failed items'
  }))
  cleanupFns.push(on(c, 'click', '#btnConfirmSync', async function (this: HTMLButtonElement) {
    if (!await dialog('Confirm that Capture One has loaded the written metadata for this session.', 'Confirm Sync')) return
    this.disabled = true; this.textContent = 'Confirming…'
    try {
      await engine.fkw.confirmSync(sessionId)
      toast('Sync confirmed. You can clean up Gather XMP sidecars when ready.', 'success')
      this.textContent = 'Synced'
      $('#btnCleanup')?.classList.remove('hidden')
    } catch (err: unknown) { this.disabled = false; this.textContent = 'Confirm Sync'; showError(err, 'Confirmation failed. Please try again or restart the application.') }
  }))
  cleanupFns.push(on(c, 'click', '#btnCleanup', async function (this: HTMLButtonElement) {
    if (!await dialog('Clean up Gather-created XMP sidecars and restore original backups where available?', 'Clean Up')) return
    this.disabled = true; this.textContent = 'Cleaning…'
    try {
      const result = await engine.fkw.cleanup(sessionId)
      const errors = Array.isArray(result?.errors) ? result.errors.length : 0
      if (errors > 0) toast(`Cleanup completed with ${errors} errors.`, 'warning')
      else toast('Cleanup complete.', 'success')
      this.textContent = 'Cleaned'
    } catch (err: unknown) { this.disabled = false; this.textContent = 'Clean Up XMP'; showError(err, 'Cleanup failed. Please check file permissions and try again.') }
  }))

  // Progress listener — primary completion notification (RAF-throttled DOM updates)
  const progress = createProgressRenderer('#fkwProgWrap .progress__fill', '#fkwProgText')

  const unsubProgress = engine.onProgress(data => {
    if (data.session_id !== sessionId) return
    progress.updateProgress(
      data.total > 0 ? (data.current / data.total) * 100 : 0,
      data.message || 'Analyzing faces…'
    )
    if (analysisDone) return
      if (data.status === AnalysisStatus.CANCELLED) {
      enginePollRef.current?.stop()
      analysisInProgress = false
      resetCancelUI()
      toast('Analysis cancelled.', 'warning')
      return
    }
    const statusComplete =
      data.status === AnalysisStatus.DONE ||
      (data.current >= data.total && data.total > 0)
    if (statusComplete) {
      enginePollRef.current?.stop()
      queueMicrotask(async () => {
        // Guard: the user may have navigated away before this microtask runs,
        // so check that the face-kw UI is still mounted.
        if (!document.getElementById('fkwClusterGrid')) return
        try {
          const data = await engine.fkw.getClusters(sessionId)
          analysisDone = true
          analysisInProgress = false
          hydrateClusterState((data.clusters as ClusterData[]) || [])
          noise = (data.noise as unknown[]) || []
          updateStats();
          ($('#btnToStep2') as HTMLButtonElement).disabled = false;
          ($('#btnFkwStart') as HTMLButtonElement).disabled = false
          resetCancelUI()
          toast('Analysis complete!', 'success')
        } catch (err: unknown) { showError(err, 'Failed to load clusters after analysis. Please try again. Ensure photos are valid image files.') }
      })
    }
  })

  // Init
  const capturedSidInit = sessionId
  engine.fkw.getClusters(sessionId).then(data => {
    if (capturedSidInit !== sessionId) return
    if (data.analysis_done) { analysisDone = true; hydrateClusterState((data.clusters as ClusterData[]) || []); noise = (data.noise as unknown[]) || []; updateStats(); ($('#btnToStep2') as HTMLButtonElement).disabled = false; ($('#btnFkwStart') as HTMLButtonElement).disabled = false }
      }).catch((err: unknown) => { showError(err, 'Failed to load clusters. Please try again. Ensure photos are valid image files.') })
  const capturedSidList = sessionId
  engine.session.list().then(sessions => {
    if (capturedSidList !== sessionId) return
    const s = sessions.find(s => s.id === sessionId); if (s) { const e = $('#fkwStatPhotos'); if (e) e.textContent = String(s.photo_count || 0) }
  }).catch((err: unknown) => { showError(err, 'Failed to load sessions. Please restart the application.') })

  // Escape key to close writeback panel
  const handleEscape = (e: KeyboardEvent) => {
    if (e.key === 'Escape' && step === 5) {
      e.preventDefault()
      updateStepper(4)
    }
  }
  document.addEventListener('keydown', handleEscape)
  cleanupFns.push(() => document.removeEventListener('keydown', handleEscape))

  registerCleanup(() => {
    if (analysisInProgress) {
      engine.fkw.cancelAnalysis(sessionId).catch(console.error)
    }
    enginePollRef.current?.stop(); unsubProgress(); engineRestartUnsub?.(); cleanupFns.forEach(fn => fn())
  })
}

// ── Internal ──

function updateStats(): void {
  let faces = 0; clusters.forEach(c => { faces += c.size || 0 }); faces += noise.length
  setText('fkwStatFaces', faces); setText('fkwStatClusters', clusters.length)
}

function startPollProgress(): void {
  enginePollRef.current = createPollLoop(
    () => engine.fkw.getClusters(sessionId),
    (data) => {
      if (analysisDone) { return true }
    if (data.status === AnalysisStatus.CANCELLED || data.status === 'cancelling') {
        analysisDone = true; analysisInProgress = false; resetCancelUI()
        toast('Analysis cancelled.', 'warning')
        return true
      }
      if (data.analysis_done) {
        analysisDone = true; analysisInProgress = false; resetCancelUI()
        hydrateClusterState((data.clusters as ClusterData[]) || []); noise = (data.noise as unknown[]) || []; updateStats();
        ($('#btnToStep2') as HTMLButtonElement).disabled = false; ($('#btnFkwStart') as HTMLButtonElement).disabled = false; toast('Analysis complete!', 'success')
        return true
      }
      if (data.status === AnalysisStatus.FAILED || data.analysis_status === AnalysisStatus.FAILED) {
        analysisInProgress = false
        showError(data.error || 'Analysis failed.', 'Analysis encountered a problem. Please try again.')
        const startBtn = $('#btnFkwStart') as HTMLButtonElement
        startBtn.disabled = false
        resetCancelUI()
        return true
      }
      return false
    },
    MAX_POLL_RETRIES_FKW,
    POLL_INTERVAL_FKW,
    (err: unknown) => { showError(err, 'Lost connection while checking analysis progress.') },
    () => {
      analysisInProgress = false
      showError(`Analysis is taking longer than expected. You can wait or cancel and try again with fewer photos.`)
      const startBtn = $('#btnFkwStart') as HTMLButtonElement
      startBtn.disabled = false
      resetCancelUI()
    },
  )
  enginePollRef.current.start(0)
}

function renderClusters(): void {
  const grid = $('#fkwClusterGrid'); if (!grid) return
  const filter = ($('#fkwFilter .active') as HTMLElement)?.dataset.filter || 'all'
  const filtered = clusters.filter(c => {
    const cid = c.cluster_id
    switch (filter) { case 'unbound': return !bindings[cid] && !skipped[cid]; case 'bound': return !!bindings[cid]; case 'skipped': return !!skipped[cid]; default: return true }
  }).sort((a, b) => (b.size || 0) - (a.size || 0))

  const existingCards = grid.querySelectorAll<HTMLElement>('.face-cluster-card')
  const filteredSet = new Set(filtered.map(c => c.cluster_id))
  if (existingCards.length > 0 && existingCards.length === filtered.length) {
    existingCards.forEach(card => { card.style.display = filteredSet.has(Number(card.dataset.cid!)) ? '' : 'none' })
    return
  }

  if (!filtered.length) {
    while (grid.firstChild) grid.removeChild(grid.firstChild)
    const emptyDiv = document.createElement('div')
    emptyDiv.className = 'empty-state'
    const textDiv = document.createElement('div')
    textDiv.className = 'empty-state__text'
    textDiv.textContent = "No clusters match the current filter. Try selecting 'All' to see all clusters."
    emptyDiv.appendChild(textDiv)
    grid.appendChild(emptyDiv)
    return
  }

  const cardMap = new Map<string, HTMLElement>()
  grid.querySelectorAll<HTMLElement>('[data-cid]').forEach(card => {
    if (card.dataset.cid) cardMap.set(card.dataset.cid, card)
  })
  const fragment = document.createDocumentFragment()

  for (const c of filtered) {
    const cid = c.cluster_id
    const b = bindings[cid]
    const sk = !!skipped[cid]
    const cls = `face-cluster-card${b ? ' bound' : ''}${sk ? ' skipped' : ''}${selectedCluster === cid ? ' selected' : ''}`
    const first = c.members[0]
    const thumb = typeof c.thumbnail_base64 === 'string' && isValidBase64(c.thumbnail_base64) ? `data:image/jpeg;base64,${c.thumbnail_base64}` : ''

    let card = cardMap.get(String(cid))
    if (card) {
      cardMap.delete(String(cid))
      card.className = cls
      const img = card.querySelector('.face-cluster-card__img') as HTMLImageElement | null
      if (img && img.getAttribute('src') !== thumb) img.setAttribute('src', thumb)
    } else {
      const badge = b ? `<span class="face-cluster-card__badge bound">${esc(b.role_name)}</span>` : sk ? '<span class="face-cluster-card__badge skipped">SKIP</span>' : ''
      const label = String(c.label || `Person-${cid}`)
      const temp = document.createElement('div')
      temp.innerHTML = `<div class="face-cluster-card" tabindex="0" role="button" data-cid="${esc(String(cid))}"><img class="face-cluster-card__img" src="${esc(thumb)}" loading="lazy" alt="${esc(label)} face cluster thumbnail"><div class="face-cluster-card__info"><div style="font-weight:600;font-size:0.88rem">${esc(label)}</div><div class="face-cluster-card__count">${c.size} face${c.size !== 1 ? 's' : ''}</div>${first ? `<div class="face-cluster-card__count" style="font-size:0.72rem">conf: ${(first.confidence * 100).toFixed(0)}%</div>` : ''}${badge}</div></div>`
      card = temp.firstElementChild as HTMLElement
    }
    card.setAttribute('aria-pressed', selectedCluster === cid ? 'true' : 'false')
    card.setAttribute('aria-label', `${String(c.label || `Person-${cid}`)}, ${c.size} face${c.size !== 1 ? 's' : ''}${b ? `, bound to ${b.role_name}` : sk ? ', skipped' : ''}`)
    fragment.appendChild(card)
  }

  cardMap.forEach(card => card.remove())
  grid.innerHTML = ''
  grid.appendChild(fragment)
}

function handleClusterClick(cid: number): void {
  if (mergeMode) {
    if (!mergeSource) {
      mergeSource = cid
      const card = ($('#fkwClusterGrid') as HTMLElement).querySelector(`[data-cid="${CSS.escape(String(cid))}"]`) as HTMLElement
      if (card) card.style.outline = '2px solid var(--accent)'
      $('#btnMergeSel')?.classList.remove('hidden')
      toast('Source selected. Click target.', '')
    } else {
      selectedCluster = cid; renderClusters()
      toast('Target selected. Click Merge.', '')
    }
    return
  }
  selectedCluster = cid; renderClusters(); ($('#btnToStep3') as HTMLButtonElement).disabled = false
}

function loadBind(): void {
  const cid = selectedCluster; if (!cid) return
  const cluster = clusters.find(c => c.cluster_id === cid)
  if (!cluster) {
    toast('Cluster not found.', 'warning')
    const prev = $('#fkwFacePrev') as HTMLImageElement; if (prev) prev.src = ''
    const list = $('#fkwMemList'); if (list) list.innerHTML = ''
    const role = $('#fkw-role') as HTMLInputElement; if (role) role.value = ''
    renderTags([])
    const e = $('#fkwBindTitle'); if (e) e.textContent = 'Select a cluster to begin.'
    return
  }
  const e = $('#fkwBindTitle'); if (e) e.textContent = 'Binding: ' + (String(cluster.label || `Person-${cid}`))
  const cnt = $('#fkwMemCnt'); if (cnt) cnt.textContent = String(cluster.size || 0)

  const thumb = typeof cluster.thumbnail_base64 === 'string' && isValidBase64(cluster.thumbnail_base64) ? cluster.thumbnail_base64 : null
  const prev = $('#fkwFacePrev') as HTMLImageElement; if (prev) { prev.src = thumb ? `data:image/jpeg;base64,${thumb}` : ''; prev.alt = `Preview for ${String(cluster.label || `Person-${cid}`)}` }

  const members = cluster.members
  const list = $('#fkwMemList'); if (list) list.innerHTML = members.map(m => {
    const fn = m.filename || (m.photo_path || '').replace(/\\/g, '/').split('/').pop() || ''
    return `<div class="fkw-member-item"><span style="color:var(--text-dim);font-size:0.72rem">📷</span> ${esc(fn)}<button class="btn btn--danger btn--sm" style="margin-left:auto;padding:0.15rem 0.4rem;font-size:0.65rem" data-remove="${esc(m.photo_id || '')}">Remove</button></div>`
  }).join('') || '<div class="text-muted text-sm">No members</div>'

  const b = bindings[cid]; const role = $('#fkw-role') as HTMLInputElement; if (role) role.value = b?.role_name || ''
  renderTags(b?.keywords || [])
}

function renderTags(tags: string[]): void { currentTags = tags || []; const editor = $('#fkwTagEditor'); const input = $('#fkw-keywords'); if (!editor || !input) return; editor.querySelectorAll('.fkw-tag').forEach(t => t.remove()); currentTags.forEach(tag => { const s = document.createElement('span'); s.className = 'fkw-tag'; s.textContent = tag; const r = document.createElement('span'); r.className = 'fkw-tag__remove'; r.dataset.tag = tag; r.setAttribute('tabindex', '0'); r.setAttribute('role', 'button'); r.dataset.action = 'remove-tag'; r.textContent = '×'; r.addEventListener('click', e => { e.stopPropagation(); currentTags = currentTags.filter(t => t !== tag); renderTags(currentTags) }); s.appendChild(r); editor.insertBefore(s, input) }) }
function addTag(v: string): void { v = v.trim().replace(/,$/, '').trim(); if (!v || currentTags.includes(v)) return; currentTags.push(v); renderTags(currentTags) }

function advanceToNext(): void {
  const sorted = [...clusters].sort((a, b) => (b.size || 0) - (a.size || 0))
  const next = sorted.find(c => { const cid = c.cluster_id; return !bindings[cid] && !skipped[cid] })
  if (next) { selectedCluster = next.cluster_id; loadBind() } else { toast('All clusters processed!', 'success'); $('#btnToStep4')?.focus() }
}

async function loadPreview(): Promise<void> {
  try {
    const data = await engine.fkw.preview(sessionId)
    previewData = (data.photos as Record<string, unknown>[]) || []
    const s = (data.stats as Record<string, number>) || {}
    const statsEl = $('#fkwPrevStats'); if (statsEl) { statsEl.textContent = ''; statsEl.append(strong(String(s.total_photos || 0)), ' photos total · ', strong(String(s.with_keywords || 0), 'var(--success)'), ' with keywords · ', strong(String(s.without_keywords || 0), 'var(--text-dim)'), ' without') }
    const tbody = $('#fkwPrevTable tbody'); if (tbody) { tbody.innerHTML = previewData.map(p => {
      const isMulti = (p.sources as unknown[] | undefined)?.length && (p.sources as unknown[]).length > 1
      return `<tr${isMulti ? ' class="multi-face"' : ''}><td>${esc(String(p.filename || ''))}</td><td>${((p.keywords as string[]) || []).map(kw => `<span class="kw-tag">${esc(kw)}</span>`).join('') || '<span class="text-muted">-</span>'}</td><td>${((p.sources as { role_name: string }[]) || []).map(src => `<span class="kw-tag" style="background:var(--card);color:var(--text-muted)">${esc(src.role_name)}</span>`).join(' ') || '<span class="text-muted">-</span>'}</td></tr>`
    }).join('') || '<tr><td colspan="3">No data.</td></tr>' }
  } catch (err: unknown) { showError(err, 'Preview failed. Please try again.') }
}

async function doWriteback(): Promise<void> {
  const fill = $('#fkwWbWrap')?.querySelector('.progress__fill') as HTMLElement | null
  const text = $('#fkwWbText')
  if (fill) { fill.style.width = '0%'; fill.classList.add('progress__fill--indeterminate') }
  if (text) text.textContent = 'Writing keywords to XMP files…'
  $('#fkwWbResults')?.classList.add('hidden')
  try {
    const r = await engine.fkw.writeback(sessionId) as Record<string, unknown>
    if (fill) { fill.classList.remove('progress__fill--indeterminate'); fill.style.width = '100%' }
    if (text) text.textContent = 'Complete.'
    setText('fkwWrWritten', (r.written ?? '-') as string | number); setText('fkwWrFailed', (r.failed ?? '-') as string | number); setText('fkwWrSkipped', (r.skipped ?? '-') as string | number)
    const hasFailures = (r.failed as number) > 0
    $('#fkwWbResults')?.classList.remove('hidden')
    if (hasFailures) {
      $('#fkwGuide')?.classList.add('hidden'); $('#btnConfirmSync')?.classList.add('hidden'); $('#btnCleanup')?.classList.add('hidden')
      $('#btnWbRetry')?.classList.remove('hidden')
    } else {
      $('#fkwGuide')?.classList.remove('hidden'); $('#btnConfirmSync')?.classList.remove('hidden'); const cleanupBtn = $('#btnCleanup') as HTMLButtonElement | null; if (cleanupBtn) { cleanupBtn.disabled = false; cleanupBtn.textContent = 'Clean Up XMP' } $('#btnCleanup')?.classList.add('hidden')
      $('#btnWbRetry')?.classList.add('hidden')
    }
    const errors = r.errors as string[] | undefined; if (errors?.length) { const msg = errors.length > 3 ? `${errors.length} files failed. First 3: ${errors.slice(0, 3).join('; ')}` : errors.slice(0, 3).join('; '); toast('Errors: ' + msg, 'warning') }
    else if (hasFailures) toast(`${r.failed} failed.`, 'warning')
    else toast(`All ${r.written} written!`, 'success')
  } catch (err: unknown) { if (fill) { fill.classList.remove('progress__fill--indeterminate'); fill.style.width = '0%' } if (text) text.textContent = 'Failed.'; $('#fkwWbResults')?.classList.add('hidden'); $('#fkwGuide')?.classList.add('hidden'); $('#btnConfirmSync')?.classList.add('hidden'); $('#btnCleanup')?.classList.add('hidden'); $('#btnWbRetry')?.classList.remove('hidden'); showError(err, 'Writeback failed. Check disk space and file permissions, then try again.'); const btn = $('#btnWb') as HTMLButtonElement | null; if (btn) btn.disabled = false }
}

function strong(text: string, color = ''): HTMLElement { const e = document.createElement('strong'); e.textContent = text; if (color) e.style.color = color; return e }
