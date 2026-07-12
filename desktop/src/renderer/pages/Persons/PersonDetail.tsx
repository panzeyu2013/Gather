import React, { useEffect, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { personApi } from '../../api/person'
import Dialog from '../../components/Dialog/Dialog'
import ConfirmDialog from '../../components/Dialog/ConfirmDialog'
import type { PersonDetailData } from '@gather/shared'
import styles from './PersonDetail.module.css'

export default function PersonDetail() {
  const { personId } = useParams<{ personId: string }>()
  const navigate = useNavigate()
  const queryClient = useQueryClient()

  const [person, setPerson] = useState<PersonDetailData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const [showEditDialog, setShowEditDialog] = useState(false)
  const [editName, setEditName] = useState('')
  const [editNotes, setEditNotes] = useState('')
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false)

  const loadPerson = async () => {
    if (!personId) return
    setLoading(true)
    setError(null)
    try {
      const data = await personApi.get(personId)
      setPerson(data)
      setLoading(false)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load person')
      setLoading(false)
    }
  }

  useEffect(() => {
    loadPerson()
  }, [personId])

  const handleEdit = () => {
    if (!person) return
    setEditName(person.name)
    setEditNotes(person.notes)
    setShowEditDialog(true)
  }

  const handleSaveEdit = async () => {
    if (!personId || !editName.trim()) return
    try {
      await personApi.update(personId, { name: editName.trim(), notes: editNotes })
      setShowEditDialog(false)
      loadPerson()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to update')
    }
  }

  const handleDelete = async () => {
    if (!personId) return
    try {
      await personApi.delete(personId)
      queryClient.invalidateQueries({ queryKey: ['persons'] })
      navigate('/persons', { replace: true })
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to delete')
    }
  }

  if (loading) {
    return (
      <div className={styles.page}>
        <div className={styles.loading}>
          <p>加载中...</p>
        </div>
      </div>
    )
  }

  if (error || !person) {
    return (
      <div className={styles.page}>
        <button className={styles.backLink} onClick={() => navigate('/persons')}>
          &larr; 返回人脸库
        </button>
        <p>{error ?? '未找到该人物'}</p>
      </div>
    )
  }

  return (
    <div className={styles.page}>
      <button className={styles.backLink} onClick={() => navigate('/persons')}>
        &larr; 返回人脸库
      </button>

      <div className={styles.header}>
        <div className={styles.headerLeft}>
          <div className={styles.avatar}>
            {person.thumbnailBase64 ? (
              <img src={`data:image/jpeg;base64,${person.thumbnailBase64}`} alt={person.name} />
            ) : (
              person.name.charAt(0)
            )}
          </div>
          <div className={styles.headerInfo}>
            <h1 className={styles.name}>{person.name}</h1>
            <p className={styles.meta}>
              {person.photoCount} 张照片 · {person.sessionCount} 个工作区 · 匹配阈值: {person.matchThreshold}
            </p>
          </div>
        </div>
        <div className={styles.headerActions}>
          <button className={styles.editBtn} onClick={handleEdit}>
            编辑
          </button>
          <button className={styles.deleteBtn} onClick={() => setShowDeleteConfirm(true)}>
            删除人物
          </button>
        </div>
      </div>

      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>信息</h2>
        <div className={styles.infoGrid}>
          <span className={styles.infoLabel}>姓名</span>
          <span className={styles.infoValue}>{person.name}</span>
          <span className={styles.infoLabel}>关键词</span>
          <span className={styles.infoValue}>
            {person.keywords && person.keywords.length > 0 ? person.keywords.join(', ') : '无'}
          </span>
          <span className={styles.infoLabel}>备注</span>
          <span className={styles.infoValue}>{person.notes || '无'}</span>
          <span className={styles.infoLabel}>匹配阈值</span>
          <span className={styles.infoValue}>{person.matchThreshold}</span>
          <span className={styles.infoLabel}>创建时间</span>
          <span className={styles.infoValue}>
            {new Date(person.createdAt).toLocaleDateString()}
          </span>
        </div>
      </div>

      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>
          关联照片 ({person.totalPhotoCount})
        </h2>
        {person.photos.length === 0 ? (
          <p className={styles.meta}>暂无关联照片</p>
        ) : (
          <div className={styles.photoGrid}>
            {person.photos.map((photo) => (
              <div key={photo.photoId} className={styles.photoCard}>
                <div className={styles.photoThumb}>
                  {photo.thumbnailBase64 ? (
                    <img src={`data:image/jpeg;base64,${photo.thumbnailBase64}`} alt={photo.filename} />
                  ) : (
                    <span className={styles.photoThumbPlaceholder}>&#128247;</span>
                  )}
                </div>
                <div className={styles.photoInfo}>
                  <p className={styles.photoName}>{photo.filename}</p>
                  <p className={styles.photoSession}>{photo.sessionName}</p>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      <Dialog open={showEditDialog} onClose={() => setShowEditDialog(false)} title="编辑人物信息">
        <div className={styles.formGroup}>
          <label className={styles.label}>姓名</label>
          <input
            className={styles.input}
            type="text"
            value={editName}
            onChange={(e) => setEditName(e.target.value)}
            autoFocus
          />
        </div>
        <div className={styles.formGroup}>
          <label className={styles.label}>备注</label>
          <textarea
            className={styles.textarea}
            value={editNotes}
            onChange={(e) => setEditNotes(e.target.value)}
            rows={3}
          />
        </div>
        <div className={styles.formActions}>
          <button className={styles.cancelBtn} onClick={() => setShowEditDialog(false)}>
            取消
          </button>
          <button
            className={styles.submitBtn}
            onClick={handleSaveEdit}
            disabled={!editName.trim()}
          >
            保存
          </button>
        </div>
      </Dialog>

      <ConfirmDialog
        open={showDeleteConfirm}
        onClose={() => setShowDeleteConfirm(false)}
        onConfirm={handleDelete}
        title="删除人物"
        message={`确定要删除 "${person.name}" 吗？此操作将从人脸库中移除该人物及其所有关联的人脸数据。`}
        confirmLabel="删除"
        destructive
      />
    </div>
  )
}
