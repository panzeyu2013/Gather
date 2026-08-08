import React, { useState, useEffect, useRef, useCallback } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { sessionApi } from '../../api/session'
import { jobsApi } from '../../api/jobs'
import { indexerApi } from '../../api/indexer'
import { useEvent } from '../../hooks/useEvent'
import { useSessionStore } from '../../stores/sessionStore'
import Dialog from '../../components/Dialog/Dialog'
import ConfirmDialog from '../../components/Dialog/ConfirmDialog'
import Badge from '../../components/Badge/Badge'
import { useToastStore } from '../../components/Toast/ToastStore'
import type { SessionData } from '@gather/shared'
import {
  getCommonParentPath,
  getPathBasename,
  importFailureMessage,
} from '../../utils/session-paths'
import {
  c1PreflightGuidance,
  evaluateC1Preflight,
  failedC1Preflight,
  type C1PreflightResult,
} from '../../utils/c1-preflight'
import { useTranslation, type TranslationKey } from '../../locales'
import { translateError } from '../../utils/errors'
import styles from './Dashboard.module.css'

export { getCommonParentPath, getPathBasename } from '../../utils/session-paths'

const SOURCE_OPTIONS: Array<{ value: string; labelKey: TranslationKey }> = [
  { value: 'local', labelKey: 'dashboard.sourceLocal' },
  { value: 'capture-one', labelKey: 'dashboard.sourceCaptureOne' },
]

/** Latest `metadata.scan` job snapshot per session, seeded from jobs.list and
 * kept live by jobs:progress frames (mirrors SessionDetail/indexProgress.ts). */
export interface DashboardScanJob {
  status?: string
  current: number
  total: number
}

export type DashboardCardIndexKind = 'failed' | 'active' | 'count'

/** 卡片计数文案决策（design_improvements.md 3.3.3 / 3.3.4）：
 * - failed（终态失败）→ 显示"索引失败"+重试，绝不以阶段计数作权威展示；
 * - active（queued/running/cancelling，含进度 0/0）→ 扫描中…/正在索引 N；
 * - count → 计数落定：scan 成功后截断导入的 ≥ 前缀也去除（与 SessionDetail
 *   indexProgress 一致）；cancelled/interrupted/无 scan 行 → 保留截断 ≥。 */
export function deriveCardIndexKind(job: DashboardScanJob | undefined): DashboardCardIndexKind {
  if (job) {
    if (job.status === 'failed') return 'failed'
    if (job.status === 'succeeded') return 'count'
    if (job.status === undefined || ['queued', 'running', 'cancelling'].includes(job.status)) {
      return 'active'
    }
  }
  return 'count'
}

export default function Dashboard() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const setSession = useSessionStore((s) => s.setSession)
  const addToast = useToastStore((s) => s.addToast)

  const [showNewDialog, setShowNewDialog] = useState(false)
  const [newName, setNewName] = useState('')
  const [newNameEdited, setNewNameEdited] = useState(false)
  const [newSource, setNewSource] = useState('local')
  const [newFolderPath, setNewFolderPath] = useState('')
  const [deleteTarget, setDeleteTarget] = useState<SessionData | null>(null)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [showBatchDeleteConfirm, setShowBatchDeleteConfirm] = useState(false)
  const [selectMode, setSelectMode] = useState(false)
  const selectAllRef = useRef<HTMLInputElement>(null)
  // Capture One 导入预检（2.3.5 P1）：进入选择前先跑 c1:health 四格检查，
  // 失败时内联展示引导，不调用 getSelectedPhotos。
  const [c1Preflight, setC1Preflight] = useState<{
    checking: boolean
    result: C1PreflightResult | null
  }>({ checking: false, result: null })
  // Sessions with a background index job (metadata.scan). The one-hop import
  // creates the row with photoCount 0 and lets the indexer fill it in, so the
  // card count must show 扫描中…/正在索引 N…/索引失败+重试 instead of an
  // authoritative number while the job runs or after it failed (文案规范,
  // design_improvements.md 3.3.3 / 3.3.4). Seeded from jobs.list so a scan
  // that finished before this page mounted (failed scans included) is still
  // reflected on the cards; jobs:progress keeps the map live afterwards.
  const [scanJobs, setScanJobs] = useState<Map<string, DashboardScanJob>>(new Map())

  useEffect(() => {
    let disposed = false
    void jobsApi.list().then((jobs) => {
      if (disposed) return
      const latest = new Map<string, { snapshot: DashboardScanJob; updatedAt: string }>()
      for (const job of jobs) {
        if (job.type !== 'metadata.scan') continue
        const previous = latest.get(job.scopeId)
        if (!previous || job.updatedAt > previous.updatedAt) {
          latest.set(job.scopeId, {
            snapshot: { status: job.status, current: job.progressCurrent, total: job.progressTotal },
            updatedAt: job.updatedAt,
          })
        }
      }
      const scanBySession = new Map<string, DashboardScanJob>()
      for (const [sessionId, { snapshot }] of latest) scanBySession.set(sessionId, snapshot)
      setScanJobs(scanBySession)
    }).catch(() => undefined)
    return () => { disposed = true }
  }, [])

  useEvent('jobs:progress', (payload) => {
    const data = payload as {
      jobType?: string
      scopeId?: string
      current?: number
      total?: number
      status?: string
    }
    if (data.jobType !== 'metadata.scan' || !data.scopeId) return
    const scopeId = data.scopeId
    const terminal = data.status && ['succeeded', 'failed', 'cancelled', 'interrupted'].includes(data.status)
    if (terminal) {
      setScanJobs((prev) => {
        const next = new Map(prev)
        if (data.status === 'failed') {
          // Keep the failed snapshot so the card shows 索引失败 + 重试 until
          // a retry re-queues the scan.
          next.set(scopeId, { status: 'failed', current: data.current ?? 0, total: data.total ?? 0 })
        } else if (data.status === 'succeeded') {
          // Keep the success marker: it is what drops the truncated ≥ prefix.
          next.set(scopeId, { status: 'succeeded', current: data.current ?? 0, total: data.total ?? 0 })
        } else {
          next.delete(scopeId)
        }
        return next
      })
      // A finished index job writes the authoritative photo_count; refresh the
      // list so the card switches from 扫描中…/正在索引 N… to the exact count.
      queryClient.invalidateQueries({ queryKey: ['sessions'] })
    } else {
      setScanJobs((prev) => new Map(prev).set(
        scopeId,
        { status: data.status, current: data.current ?? 0, total: data.total ?? 0 },
      ))
    }
  })

  const fetchC1Preflight = useCallback(async (): Promise<C1PreflightResult> => {
    try {
      const health = await window.gather.getC1Health()
      return evaluateC1Preflight(health, t)
    } catch {
      // c1Health 本身不抛异常（逐层降级返回）；IPC 异常时按全失败兜底。
      return failedC1Preflight(t)
    }
  }, [t])

  const runC1Preflight = useCallback(async () => {
    setC1Preflight(prev => ({ ...prev, checking: true }))
    const result = await fetchC1Preflight()
    setC1Preflight({ checking: false, result })
  }, [fetchC1Preflight])

  // 打开对话框且来源为 Capture One 时自动预检；切换来源时同样触发。
  useEffect(() => {
    if (!showNewDialog || newSource !== 'capture-one') return
    void runC1Preflight()
  }, [showNewDialog, newSource, runC1Preflight])

  const { data: sessions, isLoading, error } = useQuery({
    queryKey: ['sessions'],
    queryFn: sessionApi.list,
  })

  const createMutation = useMutation({
    mutationFn: async ({ name, source, folderPath }: { name: string; source: string; folderPath?: string }) => {
      if (source === 'local' && folderPath) {
        // One-hop import: only the source path crosses IPC; the main process
        // creates the session and enqueues the metadata.scan index job.
        const session = await sessionApi.createFromDirectory(name, folderPath)
        return { ...session, failedFiles: [], added: 0, skipped: 0 }
      }
      if (source === 'capture-one') {
        const files = await window.gather.getSelectedPhotos()
        if (files.length === 0) {
          throw new Error(t('dashboard.noPhotoSelectedC1'))
        }
        const sourcePath = getCommonParentPath(files)
        const sessionName = name.trim() || getPathBasename(sourcePath) || t('dashboard.c1ImportName')
        return sessionApi.create(sessionName, source, files, sourcePath)
      }
      throw new Error(t('dashboard.unsupportedSource'))
    },
    onSuccess: (session) => {
      queryClient.invalidateQueries({ queryKey: ['sessions'] })
      setShowNewDialog(false)
      setNewName('')
      setNewNameEdited(false)
      setNewSource('local')
      setNewFolderPath('')
      if (session.truncatedImport) {
        addToast(
          'warning',
          t('dashboard.truncatedToast'),
        )
      }
      if (session.failedFiles.length > 0) {
        addToast(
          'warning',
          importFailureMessage(session.added, session.failedFiles),
        )
      }
      navigate(`/sessions/${session.id}`)
    },
    onError: (error) => {
      addToast('error', error instanceof Error ? translateError(error) : t('error.createWorkspaceFailed'))
    },
  })

  const deleteMutation = useMutation({
    mutationFn: (id: string) => sessionApi.delete(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['sessions'] })
      setDeleteTarget(null)
    },
  })

  const deleteManyMutation = useMutation({
    mutationFn: (ids: string[]) => sessionApi.deleteMany(ids),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['sessions'] })
      setSelectedIds(new Set())
      setShowBatchDeleteConfirm(false)
    },
  })

  useEffect(() => {
    const el = selectAllRef.current
    if (el && sessions) {
      el.indeterminate = selectedIds.size > 0 && selectedIds.size < sessions.length
    }
  }, [selectedIds, sessions])

  const exitSelectMode = () => {
    setSelectMode(false)
    setSelectedIds(new Set())
  }

  const toggleSelectMode = () => {
    if (selectMode) {
      exitSelectMode()
    } else {
      setSelectMode(true)
    }
  }

  const toggleSelect = (id: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev)
      if (next.has(id)) {
        next.delete(id)
      } else {
        next.add(id)
      }
      return next
    })
  }

  const toggleSelectAll = () => {
    if (!sessions) return
    if (selectedIds.size === sessions.length) {
      setSelectedIds(new Set())
    } else {
      setSelectedIds(new Set(sessions.map((s) => s.id)))
    }
  }

  const handleBatchDelete = () => {
    deleteManyMutation.mutate(Array.from(selectedIds))
  }

  const handleCreate = async () => {
    if (newSource === 'local') {
      if (!newName.trim() || !newFolderPath) return
      createMutation.mutate({ name: newName.trim(), source: newSource, folderPath: newFolderPath })
      return
    }
    // Capture One 导入：先跑 c1:health 预检（2.3.5 P1），四层全部通过
    // （reachable + appRunning + automationAuthorized + documentOpen）才进入
    // getSelectedPhotos；失败时内联展示检查结果与引导，不弹原始错误 toast。
    setC1Preflight(prev => ({ ...prev, checking: true }))
    const result = await fetchC1Preflight()
    setC1Preflight({ checking: false, result })
    if (!result.passed) return
    createMutation.mutate({ name: newName.trim(), source: newSource, folderPath: newFolderPath || undefined })
  }

  const handleSelectFolder = async () => {
    const dir = await window.gather.selectDirectory(t('dialog.selectPhotoFolder'))
    if (dir) {
      setNewFolderPath(dir)
      if (!newNameEdited) {
        setNewName(getPathBasename(dir))
      }
    }
  }

  const openNewDialog = () => {
    setNewName('')
    setNewNameEdited(false)
    setNewSource('local')
    setNewFolderPath('')
    setShowNewDialog(true)
  }

  const handleAnalyze = (session: SessionData) => {
    setSession(session.id)
    navigate(`/sessions/${session.id}`)
  }

  const formatDate = (iso: string) => {
    const d = new Date(iso)
    return d.toLocaleDateString(undefined, {
      month: 'short',
      day: 'numeric',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    })
  }

  // 文案规范 (design_improvements.md 3.3.3 / 3.3.4): never present a phase
  // count as authoritative — a truncated import keeps the "≥" prefix until the
  // scan succeeds (then the exact count is authoritative and ≥ drops), a
  // session whose photos are still being filled by the index job shows
  // 扫描中…/正在索引 N…, and a failed scan shows 索引失败 + 重试.
  const photoCountLabel = (session: SessionData): string => {
    const job = scanJobs.get(session.id)
    const kind = deriveCardIndexKind(job)
    if (kind === 'failed') return t('index.failed')
    if (kind === 'active') {
      return job && job.current > 0
        ? t('dashboard.indexingCount', { count: job.current })
        : t('dashboard.scanning')
    }
    // count: authoritative only after a succeeded scan (exact photo_count);
    // cancelled/interrupted or never-scanned sessions keep ≥ on truncation.
    if (session.truncatedImport && job?.status !== 'succeeded') {
      return t('dashboard.photoCountGE', { count: session.photoCount })
    }
    return t('dashboard.photoCount', { count: session.photoCount })
  }

  // 索引失败重试：重新入队 metadata.scan（dedupeKey 复用终态行）。
  const retryScan = (sessionId: string) => {
    setScanJobs((prev) => new Map(prev).set(sessionId, { status: 'queued', current: 0, total: 0 }))
    void indexerApi.scan(sessionId).catch(() => {
      setScanJobs((prev) => {
        const next = new Map(prev)
        next.set(sessionId, { status: 'failed', current: 0, total: 0 })
        return next
      })
    })
  }

  if (isLoading) {
    return <div className={styles.page}><p>{t('dashboard.loading')}</p></div>
  }

  if (error) {
    return (
      <div className={styles.page}>
        <p>{t('error.loadWorkspacesFailed')}: {translateError(error)}</p>
      </div>
    )
  }

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <div>
          <h1 className={styles.title}>Gather</h1>
          <p className={styles.subtitle}>{t('dashboard.subtitle')}</p>
        </div>
        <div className={styles.headerActions}>
          {sessions && sessions.length > 0 && (
            <div className={styles.toolbar}>
              {selectMode ? (
                <>
                  <label className={styles.selectAllLabel}>
                    <input
                      ref={selectAllRef}
                      type="checkbox"
                      className={styles.checkbox}
                      checked={selectedIds.size === sessions.length}
                      onChange={toggleSelectAll}
                    />
                    {t('dashboard.selectAll')}
                  </label>
                  {selectedIds.size > 0 && (
                    <button
                      className={styles.batchDeleteBtn}
                      onClick={() => setShowBatchDeleteConfirm(true)}
                    >
                      {t('dashboard.deleteCount', { count: selectedIds.size })}
                    </button>
                  )}
                  <button className={styles.cancelSelectBtn} onClick={exitSelectMode}>
                    {t('dashboard.cancelSelect')}
                  </button>
                </>
              ) : (
                <button className={styles.multiSelectBtn} onClick={toggleSelectMode}>
                  {t('dashboard.multiSelect')}
                </button>
              )}
            </div>
          )}
          <button className={styles.newBtn} onClick={openNewDialog}>
            {t('dashboard.newWorkspace')}
          </button>
        </div>
      </div>

      {!sessions || sessions.length === 0 ? (
        <div className={styles.empty}>
          <div className={styles.emptyIcon}>&#128247;</div>
          <p className={styles.emptyText}>{t('dashboard.emptyText')}</p>
          <p className={styles.emptyHint}>
            {t('dashboard.emptyHint')}
          </p>
        </div>
      ) : (
          <div>
            <div className={styles.list}>
              {sessions.map((s) => (
                <div key={s.id} className={`${styles.card} ${selectedIds.has(s.id) ? styles.cardSelected : ''}`}>
                  <div className={styles.cardInfo}>
                    <h3 className={styles.cardName}>{s.name}</h3>
                    <div className={styles.cardMeta}>
                      <Badge status={s.status} />
                      <span>{photoCountLabel(s)}</span>
                      {deriveCardIndexKind(scanJobs.get(s.id)) === 'failed' && (
                        <button className={styles.actionBtn} onClick={() => retryScan(s.id)}>
                          {t('jobs.retry')}
                        </button>
                      )}
                      <span>{formatDate(s.createdAt)}</span>
                    </div>
                  </div>
                  <div className={styles.cardActions}>
                    <button className={styles.actionBtn} onClick={() => handleAnalyze(s)}>
                      {t('dashboard.enter')}
                    </button>
                    <button className={styles.deleteBtn} onClick={() => setDeleteTarget(s)}>
                      {t('dashboard.delete')}
                    </button>
                    {selectMode && (
                      <span className={styles.cardCheckbox}>
                        <input
                          type="checkbox"
                          className={styles.checkbox}
                          checked={selectedIds.has(s.id)}
                          onChange={() => toggleSelect(s.id)}
                        />
                      </span>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>
      )}

      <Dialog open={showNewDialog} onClose={() => setShowNewDialog(false)} title={t('dashboard.newWorkspace')}>
        <div className={styles.formGroup}>
          <label className={styles.label} htmlFor="dashboard-new-name">{t('dashboard.workspaceName')}</label>
          <input
            id="dashboard-new-name"
            className={styles.input}
            type="text"
            value={newName}
            onChange={(e) => {
              setNewName(e.target.value)
              setNewNameEdited(true)
            }}
            placeholder={newSource === 'local' ? t('dashboard.namePlaceholderLocal') : t('dashboard.namePlaceholderC1')}
            autoFocus
            onKeyDown={(e) => { if (e.key === 'Enter') void handleCreate() }}
          />
        </div>
        <div className={styles.formGroup}>
          <label className={styles.label} htmlFor="dashboard-new-source">{t('dashboard.importSource')}</label>
          <select
            id="dashboard-new-source"
            className={styles.select}
            value={newSource}
            onChange={(e) => {
              setNewSource(e.target.value)
              if (!newNameEdited) setNewName('')
            }}
          >
            {SOURCE_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>{t(opt.labelKey)}</option>
            ))}
          </select>
        </div>
        {newSource === 'capture-one' && (
          <div className={styles.c1Preflight} aria-live="polite">
            <p className={styles.c1PreflightTitle}>{t('dashboard.c1PreflightTitle')}</p>
            {c1Preflight.checking && (
              <p className={styles.c1PreflightStatus}>{t('dashboard.c1PreflightChecking')}</p>
            )}
            {!c1Preflight.checking && c1Preflight.result && (
              <>
                <div className={styles.c1CheckList}>
                  {c1Preflight.result.checks.map((check) => (
                    <div
                      key={check.key}
                      className={check.passed ? styles.c1CheckPass : styles.c1CheckFail}
                    >
                      <span className={styles.c1CheckMark} aria-hidden="true">
                        {check.passed ? '✓' : '✗'}
                      </span>
                      <span>{check.label}</span>
                    </div>
                  ))}
                </div>
                {c1Preflight.result.passed ? (
                  <p className={styles.c1PreflightReady}>
                    {t('dashboard.c1PreflightReady')}
                  </p>
                ) : (
                  <p className={styles.c1PreflightGuidance}>
                    {c1PreflightGuidance(c1Preflight.result.failedKeys, t)}
                  </p>
                )}
              </>
            )}
          </div>
        )}
        {newSource === 'local' && (
          <div className={styles.formGroup}>
            <label className={styles.label} htmlFor="dashboard-new-folder">{t('dashboard.folderLocation')}</label>
            <div className={styles.folderPicker}>
              <input
                id="dashboard-new-folder"
                className={styles.folderInput}
                type="text"
                value={newFolderPath}
                placeholder={t('dashboard.folderPlaceholder')}
                readOnly
              />
              <button className={styles.folderBtn} onClick={handleSelectFolder}>
                {t('dashboard.folderBtn')}
              </button>
            </div>
          </div>
        )}
        <div className={styles.formActions}>
          <button className={styles.cancelBtn} onClick={() => setShowNewDialog(false)}>
            {t('common.cancel')}
          </button>
          <button
            className={styles.submitBtn}
            onClick={() => void handleCreate()}
            disabled={
              (newSource === 'local' && (!newName.trim() || !newFolderPath)) ||
              c1Preflight.checking ||
              createMutation.isPending
            }
          >
            {createMutation.isPending ? t('dashboard.creating') : t('dashboard.create')}
          </button>
        </div>
      </Dialog>

      <ConfirmDialog
        open={deleteTarget !== null}
        onClose={() => setDeleteTarget(null)}
        onConfirm={() => { if (deleteTarget) deleteMutation.mutate(deleteTarget.id) }}
        title={t('dashboard.deleteWorkspace')}
        message={t('dashboard.deleteWorkspaceMessage', { name: deleteTarget?.name ?? '' })}
        confirmLabel={t('common.delete')}
        destructive
      />

      <ConfirmDialog
        open={showBatchDeleteConfirm}
        onClose={() => setShowBatchDeleteConfirm(false)}
        onConfirm={handleBatchDelete}
        title={t('dashboard.batchDeleteWorkspace')}
        message={t('dashboard.batchDeleteMessage', { count: selectedIds.size })}
        confirmLabel={t('dashboard.deleteAll')}
        destructive
      />
    </div>
  )
}
