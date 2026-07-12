import React, { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { usePersons, useCreatePerson } from '../../hooks/usePersons'
import Dialog from '../../components/Dialog/Dialog'
import styles from './Persons.module.css'

export default function PersonsPage() {
  const navigate = useNavigate()
  const { data: persons = [], isLoading: loading } = usePersons()
  const createPerson = useCreatePerson()

  const [search, setSearch] = useState('')
  const [showNewDialog, setShowNewDialog] = useState(false)
  const [newName, setNewName] = useState('')

  const filtered = search.trim()
    ? persons.filter((p) => p.name.toLowerCase().includes(search.toLowerCase()))
    : persons

  const handleCreate = () => {
    if (!newName.trim()) return
    createPerson.mutate({ name: newName.trim() })
    setShowNewDialog(false)
    setNewName('')
  }

  if (loading) {
    return (
      <div className={styles.page}>
        <div className={styles.header}>
          <h1 className={styles.title}>人脸库</h1>
        </div>
        <div className={styles.loading}>
          <p>加载中...</p>
        </div>
      </div>
    )
  }

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <h1 className={styles.title}>人脸库</h1>
        <div className={styles.actions}>
          <input
            className={styles.searchInput}
            type="text"
            placeholder="搜索姓名..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <button className={styles.newBtn} onClick={() => setShowNewDialog(true)}>
            + 新建
          </button>
        </div>
      </div>

      {filtered.length === 0 ? (
        <div className={styles.empty}>
          <div className={styles.emptyIcon}>&#128100;</div>
          <p className={styles.emptyText}>
            {search.trim() ? '未找到匹配的人物' : '暂无人物'}
          </p>
          <p className={styles.emptyHint}>
            {search.trim() ? '尝试其他关键词' : '新建人物以开始建立人脸库'}
          </p>
        </div>
      ) : (
        <div className={styles.grid}>
          {filtered.map((person) => (
            <div
              key={person.id}
              className={styles.card}
              onClick={() => navigate(`/persons/${person.id}`)}
            >
              <div className={styles.thumbnail}>
                {person.thumbnailBase64 ? (
                  <img src={`data:image/jpeg;base64,${person.thumbnailBase64}`} alt={person.name} />
                ) : (
                  <div className={styles.thumbnailPlaceholder}>
                    {person.name.charAt(0)}
                  </div>
                )}
              </div>
              <div className={styles.cardBody}>
                <p className={styles.cardName}>{person.name}</p>
                <p className={styles.cardMeta}>
                  {person.photoCount} 张照片 · {person.sessionCount} 个工作区
                </p>
              </div>
            </div>
          ))}
        </div>
      )}

      <Dialog open={showNewDialog} onClose={() => setShowNewDialog(false)} title="新建人物">
        <div className={styles.formGroup}>
          <label className={styles.label}>姓名</label>
          <input
            className={styles.input}
            type="text"
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder="输入人物姓名"
            autoFocus
            onKeyDown={(e) => { if (e.key === 'Enter') handleCreate() }}
          />
        </div>
        <div className={styles.formActions}>
          <button className={styles.cancelBtn} onClick={() => setShowNewDialog(false)}>
            取消
          </button>
          <button
            className={styles.submitBtn}
            onClick={handleCreate}
            disabled={!newName.trim()}
          >
            创建
          </button>
        </div>
      </Dialog>
    </div>
  )
}
