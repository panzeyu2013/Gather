import React, { useState, useEffect, useCallback, useRef } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { cullingApi } from '../../api/culling'
import { imageApi } from '../../api/image'
import type { CullingGroup } from '@gather/shared'
import styles from './Culling.module.css'

function ViewerImage({ path, className }: { path: string; className?: string }) {
  const [src, setSrc] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    imageApi.getPreview(path, 1920).then((r) => {
      if (!cancelled) setSrc(`data:image/jpeg;base64,${r.buffer}`)
    }).catch(() => {
      if (!cancelled) setSrc(null)
    })
    return () => { cancelled = true }
  }, [path])

  if (!src) {
    return <div className={className ?? styles.mainPlaceholder}>Loading...</div>
  }
  return <img src={src} alt={path} className={className} />
}

function ThumbnailImg({ path, className }: { path: string; className?: string }) {
  const [src, setSrc] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    imageApi.getThumbnail(path, 160).then((r) => {
      if (!cancelled) setSrc(`data:image/jpeg;base64,${r.buffer}`)
    }).catch(() => {
      if (!cancelled) setSrc(null)
    })
    return () => { cancelled = true }
  }, [path])

  if (!src) {
    return <div className={className ?? styles.filmstripPlaceholder} />
  }
  return <img src={src} alt={path} className={className} />
}

function WritebackDialog({
  onClose,
  sessionId,
}: {
  onClose: () => void
  sessionId: string
}) {
  const [selected, setSelected] = useState<'rating' | 'color_label' | 'keyword'>('keyword')

  const writebackMutation = useMutation({
    mutationFn: () => cullingApi.writeback(sessionId, selected),
    onSuccess: () => onClose(),
  })

  const options: { value: 'rating' | 'color_label' | 'keyword'; label: string; desc: string }[] = [
    { value: 'rating', label: 'Rating', desc: 'Keep → 5 stars, Reject → 1 star' },
    { value: 'color_label', label: 'Color Label', desc: 'Keep → Green, Reject → Red' },
    { value: 'keyword', label: 'Keyword', desc: 'Add culling:keep or culling:reject keywords' },
  ]

  return (
    <div className={styles.dialog} onClick={onClose}>
      <div className={styles.dialogContent} onClick={(e) => e.stopPropagation()}>
        <div className={styles.dialogTitle}>Select Writeback Target</div>
        <div className={styles.dialogBody}>
          {options.map((opt) => (
            <div
              key={opt.value}
              className={`${styles.dialogOption} ${selected === opt.value ? styles.dialogOptionSelected : ''}`}
              onClick={() => setSelected(opt.value)}
            >
              <div>
                <div className={styles.dialogOptionLabel}>{opt.label}</div>
                <div className={styles.dialogOptionDesc}>{opt.desc}</div>
              </div>
            </div>
          ))}
        </div>
        <div className={styles.dialogActions}>
          <button className={styles.dialogBtn} onClick={onClose}>Cancel</button>
          <button
            className={`${styles.dialogBtn} ${styles.dialogBtnPrimary}`}
            onClick={() => writebackMutation.mutate()}
            disabled={writebackMutation.isPending}
          >
            {writebackMutation.isPending ? 'Writing...' : 'Writeback'}
          </button>
        </div>
        {writebackMutation.isError && (
          <p style={{ color: '#ef5350', marginTop: 12, fontSize: 13 }}>
            {writebackMutation.error instanceof Error ? writebackMutation.error.message : 'Writeback failed'}
          </p>
        )}
        {writebackMutation.isSuccess && (
          <p style={{ color: '#4caf50', marginTop: 12, fontSize: 13 }}>Writeback complete!</p>
        )}
      </div>
    </div>
  )
}

export default function Culling() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const queryClient = useQueryClient()

  const [currentGroupIndex, setCurrentGroupIndex] = useState(0)
  const [currentPhotoIndex, setCurrentPhotoIndex] = useState(0)
  const [showWriteback, setShowWriteback] = useState(false)

  const { data: groups, isLoading } = useQuery({
    queryKey: ['culling', 'groups', sessionId],
    queryFn: () => cullingApi.getGroups(sessionId!),
    enabled: !!sessionId,
  })

  const { data: summary } = useQuery({
    queryKey: ['culling', 'summary', sessionId],
    queryFn: () => cullingApi.getSummary(sessionId!),
    enabled: !!sessionId,
  })

  useEffect(() => {
    setCurrentPhotoIndex(0)
  }, [currentGroupIndex])

  const goToGroup = useCallback((index: number) => {
    if (groups && index >= 0 && index < groups.length) {
      setCurrentGroupIndex(index)
    }
  }, [groups])

  const nextGroup = useCallback(() => {
    setCurrentGroupIndex((i) => (groups && i < groups.length - 1) ? i + 1 : i)
  }, [groups])

  const prevGroup = useCallback(() => {
    setCurrentGroupIndex((i) => i > 0 ? i - 1 : i)
  }, [])

  const decideMutation = useMutation({
    mutationFn: ({ photoId, decision }: { photoId: string; decision: 'keep' | 'reject' | 'pending' }) =>
      cullingApi.decide(sessionId!, photoId, decision),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['culling'] })
    },
  })

  const currentGroup = groups?.[currentGroupIndex] ?? null
  const currentPhoto = currentGroup?.images[currentPhotoIndex] ?? null

  const handleDecide = useCallback(
    (decision: 'keep' | 'reject' | 'pending') => {
      if (!currentPhoto?.photoId || !sessionId) return
      decideMutation.mutate({ photoId: currentPhoto.photoId, decision })
    },
    [currentPhoto, sessionId, decideMutation],
  )

  const goToPhoto = useCallback(
    (index: number) => {
      if (currentGroup && index >= 0 && index < currentGroup.images.length) {
        setCurrentPhotoIndex(index)
      }
    },
    [currentGroup],
  )

  const goToNextPhoto = useCallback(() => {
    if (currentGroup && currentPhotoIndex < currentGroup.images.length - 1) {
      setCurrentPhotoIndex((i) => i + 1)
    }
  }, [currentGroup, currentPhotoIndex])

  const goToPrevPhoto = useCallback(() => {
    if (currentPhotoIndex > 0) {
      setCurrentPhotoIndex((i) => i - 1)
    }
  }, [currentPhotoIndex])

  const handleDecideRef = useRef(handleDecide)
  const goToPrevPhotoRef = useRef(goToPrevPhoto)
  const goToNextPhotoRef = useRef(goToNextPhoto)
  const prevGroupRef = useRef(prevGroup)
  const nextGroupRef = useRef(nextGroup)

  useEffect(() => {
    handleDecideRef.current = handleDecide
    goToPrevPhotoRef.current = goToPrevPhoto
    goToNextPhotoRef.current = goToNextPhoto
    prevGroupRef.current = prevGroup
    nextGroupRef.current = nextGroup
  })

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (showWriteback) return

      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return

      switch (e.key) {
        case 'y':
        case 'Y':
          e.preventDefault()
          handleDecideRef.current('keep')
          break
        case 'n':
        case 'N':
          e.preventDefault()
          handleDecideRef.current('reject')
          break
        case ' ':
          e.preventDefault()
          handleDecideRef.current('pending')
          break
        case 'ArrowLeft':
          e.preventDefault()
          goToPrevPhotoRef.current()
          break
        case 'ArrowRight':
          e.preventDefault()
          goToNextPhotoRef.current()
          break
        case 'Tab':
          e.preventDefault()
          if (e.shiftKey) {
            prevGroupRef.current()
          } else {
            nextGroupRef.current()
          }
          break
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [showWriteback])

  if (!sessionId) {
    return <div className={styles.page}><div className={styles.emptyState}>No session selected</div></div>
  }

  if (isLoading) {
    return <div className={styles.page}><div className={styles.emptyState}>Loading...</div></div>
  }

  if (!groups || groups.length === 0) {
    return (
      <div className={styles.page}>
        <div className={styles.emptyState}>
          No similarity groups found. Run similarity analysis first.
        </div>
      </div>
    )
  }

  const hasDecisions = currentGroup
    ? currentGroup.keepCount + currentGroup.rejectCount > 0
    : false

  const decisionBadgeClass = currentPhoto
    ? currentPhoto.decision === 'keep'
      ? styles.badgeKeep
      : currentPhoto.decision === 'reject'
        ? styles.badgeReject
        : styles.badgePending
    : ''

  const decisionLabel = currentPhoto
    ? currentPhoto.decision === 'keep'
      ? 'KEEP'
      : currentPhoto.decision === 'reject'
        ? 'REJECT'
        : ''
    : ''

  return (
    <div className={styles.page}>
      <div className={styles.mainViewer}>
        {currentPhoto ? (
          <>
            {currentPhotoIndex > 0 && (
              <button className={`${styles.navBtn} ${styles.navPrev}`} onClick={goToPrevPhoto}>
                ‹
              </button>
            )}
            {currentPhoto.decision !== 'pending' && (
              <div className={`${styles.decisionBadge} ${decisionBadgeClass}`}>{decisionLabel}</div>
            )}
            <ViewerImage path={currentPhoto.filepath} className={styles.mainImage} />
            {currentPhotoIndex < currentGroup!.images.length - 1 && (
              <button className={`${styles.navBtn} ${styles.navNext}`} onClick={goToNextPhoto}>
                ›
              </button>
            )}
          </>
        ) : (
          <div className={styles.mainPlaceholder}>No photo</div>
        )}
      </div>

      {currentGroup && (
        <div className={styles.progressBar}>
          <div className={styles.progressLeft}>
            <span>Group {currentGroupIndex + 1} of {groups!.length}</span>
            <div className={styles.progressBarFill}>
              <div
                className={styles.progressBarInner}
                style={{ width: `${((currentGroupIndex + 1) / groups!.length) * 100}%` }}
              />
            </div>
          </div>
          <div className={styles.progressRight}>
            <span className={styles.statKeep}>{currentGroup.keepCount} kept</span>
            <span className={styles.statReject}>{currentGroup.rejectCount} rejected</span>
            <span className={styles.statPending}>{currentGroup.pendingCount} pending</span>
            <span className={styles.shortcutHint}>Y/N/Space</span>
          </div>
        </div>
      )}

      {currentGroup && (
        <div className={styles.filmstrip}>
          {currentGroup.images.map((img, idx) => (
            <div
              key={img.photoId || idx}
              className={`${styles.filmstripItem} ${idx === currentPhotoIndex ? styles.filmstripItemActive : ''}`}
              onClick={() => goToPhoto(idx)}
            >
              <ThumbnailImg path={img.filepath} className={styles.filmstripImg} />
              <div
                className={`${styles.filmstripBadge} ${
                  img.decision === 'keep'
                    ? styles.filmstripBadgeKeep
                    : img.decision === 'reject'
                      ? styles.filmstripBadgeReject
                      : styles.filmstripBadgePending
                }`}
              />
            </div>
          ))}
        </div>
      )}

      <div className={styles.controls}>
        <button className={`${styles.controlBtn} ${styles.btnKeep}`} onClick={() => handleDecide('keep')}>
          Keep (Y)
        </button>
        <button className={`${styles.controlBtn} ${styles.btnReject}`} onClick={() => handleDecide('reject')}>
          Reject (N)
        </button>
        <button className={styles.controlBtn} onClick={() => handleDecide('pending')}>
          Skip (Space)
        </button>
        <button className={styles.controlBtn} onClick={prevGroup} disabled={currentGroupIndex === 0}>
          Prev Group
        </button>
        <button className={styles.controlBtn} onClick={nextGroup} disabled={currentGroupIndex >= groups!.length - 1}>
          Next Group (Tab)
        </button>
        {hasDecisions && (
          <button className={`${styles.controlBtn} ${styles.btnWriteback}`} onClick={() => setShowWriteback(true)}>
            Writeback
          </button>
        )}
      </div>

      {showWriteback && (
        <WritebackDialog
          sessionId={sessionId}
          onClose={() => setShowWriteback(false)}
        />
      )}
    </div>
  )
}
