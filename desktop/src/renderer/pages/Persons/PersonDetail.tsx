import React, { useEffect, useRef, useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { personApi } from '../../api/person'
import { imageApi } from '../../api/image'
import Dialog from '../../components/Dialog/Dialog'
import ConfirmDialog from '../../components/Dialog/ConfirmDialog'
import type { PersonDetailData, PersonPhotoItem } from '@gather/shared'
import { useTranslation } from '../../locales'
import { translateError } from '../../utils/errors'
import styles from './PersonDetail.module.css'

function PersonAvatar({ person }: { person: PersonDetailData }) {
  const src = person.thumbnailPath
    ? imageApi.thumbnailUrl(person.thumbnailPath, 256)
    : person.thumbnailBase64
      ? `data:image/jpeg;base64,${person.thumbnailBase64}`
      : null
  const [failed, setFailed] = useState(false)
  const lastSrcRef = useRef(src)
  // Navigating between persons reuses this instance; a stale `failed` flag
  // must not hide a freshly loaded avatar.
  if (lastSrcRef.current !== src) {
    lastSrcRef.current = src
    setFailed(false)
  }
  if (!src || failed) {
    return person.name.charAt(0)
  }
  return (
    <img src={src} alt={person.name} loading="lazy" onError={() => setFailed(true)} />
  )
}

function PhotoThumb({ photo }: { photo: PersonPhotoItem }) {
  const [failed, setFailed] = useState(false)
  if (failed) {
    return <span className={styles.photoThumbPlaceholder}>&#128247;</span>
  }
  return (
    <img
      src={imageApi.thumbnailUrl(photo.filepath, 256)}
      alt={photo.filename}
      loading="lazy"
      onError={() => setFailed(true)}
    />
  )
}

export default function PersonDetail() {
  const { t } = useTranslation()
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
      setError(e instanceof Error ? translateError(e) : t('error.loadPersonFailed'))
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
      setError(e instanceof Error ? translateError(e) : t('error.updatePersonFailed'))
    }
  }

  const handleDelete = async () => {
    if (!personId) return
    try {
      await personApi.delete(personId)
      queryClient.invalidateQueries({ queryKey: ['persons'] })
      navigate('/persons', { replace: true })
    } catch (e) {
      setError(e instanceof Error ? translateError(e) : t('error.deletePersonFailed'))
    }
  }

  if (loading) {
    return (
      <div className={styles.page}>
        <div className={styles.loading}>
          <p>{t('persons.loading')}</p>
        </div>
      </div>
    )
  }

  if (error || !person) {
    return (
      <div className={styles.page}>
        <button className={styles.backLink} onClick={() => navigate('/persons')}>
          &larr; {t('persons.back')}
        </button>
        <p>{error ?? t('persons.notFound')}</p>
      </div>
    )
  }

  return (
    <div className={styles.page}>
      <button className={styles.backLink} onClick={() => navigate('/persons')}>
        &larr; {t('persons.back')}
      </button>

      <div className={styles.header}>
        <div className={styles.headerLeft}>
          <div className={styles.avatar}>
            <PersonAvatar person={person} />
          </div>
          <div className={styles.headerInfo}>
            <h1 className={styles.name}>{person.name}</h1>
            <p className={styles.meta}>
              {t('persons.meta', {
                photos: person.photoCount,
                sessions: person.sessionCount,
                threshold: person.matchThreshold,
              })}
            </p>
          </div>
        </div>
        <div className={styles.headerActions}>
          <button
            className={styles.reviewBtn}
            onClick={() => {
              const sessionId = person.photos[0]?.sessionId
              if (!sessionId) return
              navigate(`/sessions/${sessionId}/face-kw?role=${encodeURIComponent(person.name)}`)
            }}
            disabled={person.photos.length === 0}
            title={person.photos.length === 0 ? t('persons.goReviewDisabled') : t('persons.goReviewTitle')}
          >
            {t('persons.goReview')}
          </button>
          <button className={styles.editBtn} onClick={handleEdit}>
            {t('persons.edit')}
          </button>
          <button className={styles.deleteBtn} onClick={() => setShowDeleteConfirm(true)}>
            {t('persons.delete')}
          </button>
        </div>
      </div>

      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>{t('persons.info')}</h2>
        <div className={styles.infoGrid}>
          <span className={styles.infoLabel}>{t('persons.name')}</span>
          <span className={styles.infoValue}>{person.name}</span>
          <span className={styles.infoLabel}>{t('persons.keywords')}</span>
          <span className={styles.infoValue}>
            {person.keywords && person.keywords.length > 0 ? person.keywords.join(', ') : t('persons.none')}
          </span>
          <span className={styles.infoLabel}>{t('persons.notes')}</span>
          <span className={styles.infoValue}>{person.notes || t('persons.none')}</span>
          <span className={styles.infoLabel}>{t('persons.matchThreshold')}</span>
          <span className={styles.infoValue}>{person.matchThreshold}</span>
          <span className={styles.infoLabel}>{t('persons.createdAt')}</span>
          <span className={styles.infoValue}>
            {new Date(person.createdAt).toLocaleDateString()}
          </span>
        </div>
      </div>

      <div className={styles.section}>
        <h2 className={styles.sectionTitle}>
          {t('persons.photosCount', { count: person.totalPhotoCount })}
        </h2>
        {person.photos.length === 0 ? (
          <p className={styles.meta}>{t('persons.noPhotos')}</p>
        ) : (
          <div className={styles.photoGrid}>
            {person.photos.map((photo) => (
              <div key={photo.photoId} className={styles.photoCard}>
                <div className={styles.photoThumb}>
                  <PhotoThumb photo={photo} />
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

      <Dialog open={showEditDialog} onClose={() => setShowEditDialog(false)} title={t('persons.editTitle')}>
        <div className={styles.formGroup}>
          <label className={styles.label}>{t('persons.name')}</label>
          <input
            className={styles.input}
            type="text"
            value={editName}
            onChange={(e) => setEditName(e.target.value)}
            autoFocus
          />
        </div>
        <div className={styles.formGroup}>
          <label className={styles.label}>{t('persons.notes')}</label>
          <textarea
            className={styles.textarea}
            value={editNotes}
            onChange={(e) => setEditNotes(e.target.value)}
            rows={3}
          />
        </div>
        <div className={styles.formActions}>
          <button className={styles.cancelBtn} onClick={() => setShowEditDialog(false)}>
            {t('common.cancel')}
          </button>
          <button
            className={styles.submitBtn}
            onClick={handleSaveEdit}
            disabled={!editName.trim()}
          >
            {t('common.save')}
          </button>
        </div>
      </Dialog>

      <ConfirmDialog
        open={showDeleteConfirm}
        onClose={() => setShowDeleteConfirm(false)}
        onConfirm={handleDelete}
        title={t('persons.deleteTitle')}
        message={t('persons.deleteMessage', { name: person.name })}
        confirmLabel={t('common.delete')}
        destructive
      />
    </div>
  )
}
