import React, { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { usePersons, useCreatePerson } from '../../hooks/usePersons'
import Dialog from '../../components/Dialog/Dialog'
import { useTranslation } from '../../locales'
import styles from './Persons.module.css'

export default function PersonsPage() {
  const { t } = useTranslation()
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
          <h1 className={styles.title}>{t('persons.title')}</h1>
        </div>
        <div className={styles.loading}>
          <p>{t('persons.loading')}</p>
        </div>
      </div>
    )
  }

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <h1 className={styles.title}>{t('persons.title')}</h1>
        <div className={styles.actions}>
          <input
            className={styles.searchInput}
            type="text"
            placeholder={t('persons.searchPlaceholder')}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <button className={styles.newBtn} onClick={() => setShowNewDialog(true)}>
            {t('persons.new')}
          </button>
        </div>
      </div>

      {filtered.length === 0 ? (
        <div className={styles.empty}>
          <div className={styles.emptyIcon}>&#128100;</div>
          <p className={styles.emptyText}>
            {search.trim() ? t('persons.noMatch') : t('persons.emptyTitle')}
          </p>
          <p className={styles.emptyHint}>
            {search.trim() ? t('persons.noMatchHint') : t('persons.emptyHint')}
          </p>
        </div>
      ) : (
        <div className={styles.grid}>
          {filtered.map((person) => (
            <button
              key={person.id}
              type="button"
              className={styles.card}
              onClick={() => navigate(`/persons/${person.id}`)}
            >
              <span className={styles.thumbnail}>
                {person.thumbnailBase64 ? (
                  <img src={`data:image/jpeg;base64,${person.thumbnailBase64}`} alt={person.name} />
                ) : (
                  <span className={styles.thumbnailPlaceholder}>
                    {person.name.charAt(0)}
                  </span>
                )}
              </span>
              <span className={styles.cardBody}>
                <span className={styles.cardName}>{person.name}</span>
                <span className={styles.cardMeta}>
                  {t('persons.photoCount', { photos: person.photoCount, sessions: person.sessionCount })}
                </span>
              </span>
            </button>
          ))}
        </div>
      )}

      <Dialog open={showNewDialog} onClose={() => setShowNewDialog(false)} title={t('persons.newDialogTitle')}>
        <div className={styles.formGroup}>
          <label className={styles.label}>{t('persons.name')}</label>
          <input
            className={styles.input}
            type="text"
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder={t('persons.namePlaceholder')}
            autoFocus
            onKeyDown={(e) => { if (e.key === 'Enter') handleCreate() }}
          />
        </div>
        <div className={styles.formActions}>
          <button className={styles.cancelBtn} onClick={() => setShowNewDialog(false)}>
            {t('common.cancel')}
          </button>
          <button
            className={styles.submitBtn}
            onClick={handleCreate}
            disabled={!newName.trim()}
          >
            {t('persons.create')}
          </button>
        </div>
      </Dialog>
    </div>
  )
}
