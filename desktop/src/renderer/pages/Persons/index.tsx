import React, { useState, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { usePersons, useCreatePerson } from '../../hooks/usePersons'
import { imageApi } from '../../api/image'
import type { PersonData } from '@gather/shared'
import Dialog from '../../components/Dialog/Dialog'
import { useTranslation } from '../../locales'
import styles from './Persons.module.css'

function PersonAvatar({ person }: { person: PersonData }) {
  const src = person.thumbnailPath
    ? imageApi.thumbnailUrl(person.thumbnailPath, 256)
    : person.thumbnailBase64
      ? `data:image/jpeg;base64,${person.thumbnailBase64}`
      : null
  const [failed, setFailed] = useState(false)
  const lastSrcRef = useRef(src)
  // A refreshed list can reuse this instance for a changed avatar source;
  // a stale `failed` flag must not hide an image that now loads.
  if (lastSrcRef.current !== src) {
    lastSrcRef.current = src
    setFailed(false)
  }
  if (!src || failed) {
    return <div className={styles.thumbnailPlaceholder}>{person.name.charAt(0)}</div>
  }
  return (
    <img src={src} alt={person.name} loading="lazy" onError={() => setFailed(true)} />
  )
}

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
              <div className={styles.thumbnail}>
                <PersonAvatar person={person} />
              </div>
              <div className={styles.cardBody}>
                <p className={styles.cardName}>{person.name}</p>
                <p className={styles.cardMeta}>
                  {t('persons.photoCount', { photos: person.photoCount, sessions: person.sessionCount })}
                </p>
              </div>
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
