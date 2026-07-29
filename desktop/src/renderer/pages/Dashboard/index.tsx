import React, { useState, useEffect, useRef } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { sessionApi } from '../../api/session'
import { useSessionStore } from '../../stores/sessionStore'
import Dialog from '../../components/Dialog/Dialog'
import ConfirmDialog from '../../components/Dialog/ConfirmDialog'
import Badge from '../../components/Badge/Badge'
import { useToastStore } from '../../components/Toast/ToastStore'
import type { SessionData } from '@gather/shared'
import styles from './Dashboard.module.css'

const SOURCE_OPTIONS = [
  { value: 'local', label: '本地文件夹' },
  { value: 'capture-one', label: 'Capture One' },
]

export function getPathBasename(filepath: string): string {
  return filepath.replace(/[\\/]+$/, '').split(/[\\/]/).pop() ?? ''
}

export function getCommonParentPath(filepaths: string[]): string {
  if (filepaths.length === 0) return ''
  const getParent = (filepath: string) => {
    const normalized = filepath.replace(/[\\/]+$/, '')
    const separatorIndex = Math.max(normalized.lastIndexOf('/'), normalized.lastIndexOf('\\'))
    return separatorIndex > 0 ? normalized.slice(0, separatorIndex) : ''
  }
  const directories = filepaths.map(getParent)
  let candidate = directories[0]
  while (candidate) {
    const prefix = `${candidate}${candidate.includes('\\') ? '\\' : '/'}`
    if (directories.every((directory) => directory === candidate || directory.startsWith(prefix))) {
      return candidate
    }
    candidate = getParent(candidate)
  }
  return directories[0]
}

function importFailureMessage(
  added: number,
  failedFiles: string[],
  sourceLabel = '文件',
): string {
  const examples = failedFiles
    .slice(0, 3)
    .map((filepath) => filepath.split(/[/\\]/).pop() ?? filepath)
    .join('、')
  const remaining = failedFiles.length > 3
    ? ` 等 ${failedFiles.length} 个`
    : ''
  return `${added} 张照片已导入；${sourceLabel}读取失败：${examples}${remaining}`
}

export default function Dashboard() {
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

  const { data: sessions, isLoading, error } = useQuery({
    queryKey: ['sessions'],
    queryFn: sessionApi.list,
  })

  const createMutation = useMutation({
    mutationFn: async ({ name, source, folderPath }: { name: string; source: string; folderPath?: string }) => {
      if (source === 'local' && folderPath) {
        const files = await window.gather.scanDirectory(folderPath)
        return sessionApi.create(name, source, files, folderPath)
      }
      if (source === 'capture-one') {
        const files = await window.gather.getSelectedPhotos()
        if (files.length === 0) {
          throw new Error('请先在 Capture One 中选择至少一张照片')
        }
        const sourcePath = getCommonParentPath(files)
        const sessionName = name.trim() || getPathBasename(sourcePath) || 'Capture One 导入'
        return sessionApi.create(sessionName, source, files, sourcePath)
      }
      throw new Error('不支持的导入来源')
    },
    onSuccess: (session) => {
      queryClient.invalidateQueries({ queryKey: ['sessions'] })
      setShowNewDialog(false)
      setNewName('')
      setNewNameEdited(false)
      setNewSource('local')
      setNewFolderPath('')
      if (session.failedFiles.length > 0) {
        addToast(
          'warning',
          importFailureMessage(session.added, session.failedFiles),
        )
      }
      navigate(`/sessions/${session.id}/gallery`)
    },
    onError: (error) => {
      addToast('error', error instanceof Error ? error.message : '创建工作区失败')
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

  const addPhotosMutation = useMutation({
    mutationFn: ({ sessionId, files }: { sessionId: string; files: string[] }) =>
      sessionApi.addPhotos(sessionId, files),
    onSuccess: (result, variables) => {
      queryClient.invalidateQueries({ queryKey: ['sessions'] })
      if (result.failedFiles.length > 0) {
        addToast(
          'warning',
          importFailureMessage(result.added, result.failedFiles),
        )
      }
      const session = sessions?.find(s => s.id === variables.sessionId)
      if (session) {
        setSession(session.id)
        navigate(`/sessions/${session.id}/gallery`)
      }
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

  useEffect(() => {
    const unsub = window.gather.onPluginImport(async (files) => {
      const now = new Date()
      const sourcePath = getCommonParentPath(files)
      const name = getPathBasename(sourcePath) ||
        `C1 导入 ${now.getMonth() + 1}/${now.getDate()} ${now.getHours()}:${String(now.getMinutes()).padStart(2, '0')}`
      try {
        const session = await sessionApi.create(name, 'capture-one', files, sourcePath)
        if (session.failedFiles.length > 0) {
          addToast(
            'warning',
            importFailureMessage(
              session.added,
              session.failedFiles,
              'Capture One 文件',
            ),
          )
        }
        setSession(session.id)
        navigate(`/sessions/${session.id}/gallery`)
      } catch (err) {
        console.error('Plugin import failed:', err)
        addToast(
          'error',
          err instanceof Error ? err.message : 'Capture One 照片导入失败',
        )
      }
    })
    return unsub
  }, [navigate, setSession, addToast])

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

  const handleCreate = () => {
    if (newSource === 'local' && !newName.trim()) return
    if (newSource === 'local' && !newFolderPath) return
    createMutation.mutate({ name: newName.trim(), source: newSource, folderPath: newFolderPath || undefined })
  }

  const handleSelectFolder = async () => {
    const dir = await window.gather.selectDirectory()
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
    navigate(`/sessions/${session.id}/gallery`)
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

  if (isLoading) {
    return <div className={styles.page}><p>加载工作区中...</p></div>
  }

  if (error) {
    return (
      <div className={styles.page}>
        <p>加载工作区失败: {error instanceof Error ? error.message : '未知错误'}</p>
      </div>
    )
  }

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <h1 className={styles.title}>Gather</h1>
        <button className={styles.newBtn} onClick={openNewDialog}>
          + 新建工作区
        </button>
      </div>

      {!sessions || sessions.length === 0 ? (
        <div className={styles.empty}>
          <div className={styles.emptyIcon}>&#128247;</div>
          <p className={styles.emptyText}>暂无工作区</p>
          <p className={styles.emptyHint}>
            创建新的工作区以开始整理照片
          </p>
        </div>
      ) : (
          <div>
            <div className={styles.toolbar}>
              {selectMode ? (
                <>
                  <label className={styles.selectAllLabel}>
                    <input
                      ref={selectAllRef}
                      type="checkbox"
                      className={styles.checkbox}
                      checked={sessions.length > 0 && selectedIds.size === sessions.length}
                      onChange={toggleSelectAll}
                    />
                    全选
                  </label>
                  {selectedIds.size > 0 && (
                    <button
                      className={styles.batchDeleteBtn}
                      onClick={() => setShowBatchDeleteConfirm(true)}
                    >
                      删除 {selectedIds.size} 个工作区
                    </button>
                  )}
                  <button className={styles.cancelSelectBtn} onClick={exitSelectMode}>
                    取消
                  </button>
                </>
              ) : (
                <button className={styles.multiSelectBtn} onClick={toggleSelectMode}>
                  多选
                </button>
              )}
            </div>
            <div className={styles.list}>
              {sessions.map((s) => (
                <div key={s.id} className={`${styles.card} ${selectedIds.has(s.id) ? styles.cardSelected : ''}`}>
                  <div className={styles.cardInfo}>
                    <h3 className={styles.cardName}>{s.name}</h3>
                    <div className={styles.cardMeta}>
                      <Badge status={s.status} />
                      <span>{s.photoCount} 张照片</span>
                      <span>{formatDate(s.createdAt)}</span>
                    </div>
                  </div>
                  <div className={styles.cardActions}>
                    <button className={styles.actionBtn} onClick={() => handleAnalyze(s)}>
                      进入
                    </button>
                    <button className={styles.deleteBtn} onClick={() => setDeleteTarget(s)}>
                      删除
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

      <Dialog open={showNewDialog} onClose={() => setShowNewDialog(false)} title="新建工作区">
        <div className={styles.formGroup}>
          <label className={styles.label}>工作区名称</label>
          <input
            className={styles.input}
            type="text"
            value={newName}
            onChange={(e) => {
              setNewName(e.target.value)
              setNewNameEdited(true)
            }}
            placeholder={newSource === 'local' ? '选择文件夹后自动生成' : '留空则使用照片所在文件夹名称'}
            autoFocus
            onKeyDown={(e) => { if (e.key === 'Enter') handleCreate() }}
          />
        </div>
        <div className={styles.formGroup}>
          <label className={styles.label}>导入来源</label>
          <select
            className={styles.select}
            value={newSource}
            onChange={(e) => {
              setNewSource(e.target.value)
              if (!newNameEdited) setNewName('')
            }}
          >
            {SOURCE_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>{opt.label}</option>
            ))}
          </select>
        </div>
        {newSource === 'local' && (
          <div className={styles.formGroup}>
            <label className={styles.label}>文件夹位置</label>
            <div className={styles.folderPicker}>
              <input
                className={styles.folderInput}
                type="text"
                value={newFolderPath}
                placeholder="请选择包含照片的文件夹"
                readOnly
              />
              <button className={styles.folderBtn} onClick={handleSelectFolder}>
                选择文件夹
              </button>
            </div>
          </div>
        )}
        <div className={styles.formActions}>
          <button className={styles.cancelBtn} onClick={() => setShowNewDialog(false)}>
            取消
          </button>
          <button
            className={styles.submitBtn}
            onClick={handleCreate}
            disabled={(newSource === 'local' && (!newName.trim() || !newFolderPath)) || createMutation.isPending}
          >
            {createMutation.isPending ? '创建中...' : '创建'}
          </button>
        </div>
      </Dialog>

      <ConfirmDialog
        open={deleteTarget !== null}
        onClose={() => setDeleteTarget(null)}
        onConfirm={() => { if (deleteTarget) deleteMutation.mutate(deleteTarget.id) }}
        title="删除工作区"
        message={`确定要删除 "${deleteTarget?.name ?? ''}" 吗？这将移除该工作区中的所有照片和结果。`}
        confirmLabel="删除"
        destructive
      />

      <ConfirmDialog
        open={showBatchDeleteConfirm}
        onClose={() => setShowBatchDeleteConfirm(false)}
        onConfirm={handleBatchDelete}
        title="批量删除工作区"
        message={`确定要删除选中的 ${selectedIds.size} 个工作区吗？这将移除这些工作区中的所有照片和结果，不可恢复。`}
        confirmLabel="删除全部"
        destructive
      />
    </div>
  )
}
