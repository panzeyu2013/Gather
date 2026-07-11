import React, { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import { sessionApi } from '../../api/session'
import { useSessionStore } from '../../stores/sessionStore'
import Dialog from '../../components/Dialog/Dialog'
import ConfirmDialog from '../../components/Dialog/ConfirmDialog'
import Badge from '../../components/Badge/Badge'
import type { SessionData } from '@gather/shared'
import styles from './Dashboard.module.css'

const SOURCE_OPTIONS = [
  { value: 'local', label: '本地文件夹' },
  { value: 'capture-one', label: 'Capture One' },
]

export default function Dashboard() {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const setSession = useSessionStore((s) => s.setSession)

  const [showNewDialog, setShowNewDialog] = useState(false)
  const [newName, setNewName] = useState('')
  const [newSource, setNewSource] = useState('local')
  const [deleteTarget, setDeleteTarget] = useState<SessionData | null>(null)

  const { data: sessions, isLoading, error } = useQuery({
    queryKey: ['sessions'],
    queryFn: sessionApi.list,
  })

  const createMutation = useMutation({
    mutationFn: ({ name, source }: { name: string; source: string }) =>
      sessionApi.create(name, source),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['sessions'] })
      setShowNewDialog(false)
      setNewName('')
      setNewSource('local')
    },
  })

  const deleteMutation = useMutation({
    mutationFn: (id: string) => sessionApi.delete(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['sessions'] })
      setDeleteTarget(null)
    },
  })

  const handleCreate = () => {
    if (!newName.trim()) return
    createMutation.mutate({ name: newName.trim(), source: newSource })
  }

  const handleAnalyze = (session: SessionData) => {
    setSession(session.id)
    navigate(`/similarity/${session.id}`)
  }

  const handleView = (session: SessionData) => {
    setSession(session.id)
    navigate(`/face-kw/${session.id}`)
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
        <button className={styles.newBtn} onClick={() => setShowNewDialog(true)}>
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
        <div className={styles.list}>
          {sessions.map((s) => (
            <div key={s.id} className={styles.card}>
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
                  分析
                </button>
                <button className={styles.actionBtn} onClick={() => handleView(s)}>
                  查看
                </button>
                <button className={styles.deleteBtn} onClick={() => setDeleteTarget(s)}>
                  删除
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      <Dialog open={showNewDialog} onClose={() => setShowNewDialog(false)} title="新建工作区">
        <div className={styles.formGroup}>
          <label className={styles.label}>工作区名称</label>
          <input
            className={styles.input}
            type="text"
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder="我的照片工作区"
            autoFocus
            onKeyDown={(e) => { if (e.key === 'Enter') handleCreate() }}
          />
        </div>
        <div className={styles.formGroup}>
          <label className={styles.label}>导入来源</label>
          <select
            className={styles.select}
            value={newSource}
            onChange={(e) => setNewSource(e.target.value)}
          >
            {SOURCE_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>{opt.label}</option>
            ))}
          </select>
        </div>
        <div className={styles.formActions}>
          <button className={styles.cancelBtn} onClick={() => setShowNewDialog(false)}>
            取消
          </button>
          <button
            className={styles.submitBtn}
            onClick={handleCreate}
            disabled={!newName.trim() || createMutation.isPending}
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
    </div>
  )
}
