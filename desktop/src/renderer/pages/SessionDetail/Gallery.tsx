import React, { useState, useEffect, useRef } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { sessionApi } from '../../api/session'
import { imageApi } from '../../api/image'
import { useSessionStore } from '../../stores/sessionStore'
import Lightbox from '../../components/Lightbox/Lightbox'
import type { PhotoData } from '@gather/shared'
import styles from './Gallery.module.css'

const FILTER_OPTIONS = [
  { value: 'all', label: '全部' },
  { value: 'hasFace', label: '有人脸' },
  { value: 'noFace', label: '无人脸' },
]

export default function Gallery() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const setSession = useSessionStore((s) => s.setSession)

  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState('all')
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null)

  const { data: photos, isLoading } = useQuery({
    queryKey: ['photos', sessionId],
    queryFn: () => sessionApi.getPhotos(sessionId!),
    enabled: !!sessionId,
  })

  useEffect(() => {
    if (sessionId) setSession(sessionId)
  }, [sessionId, setSession])

  const filtered = (photos ?? []).filter((p) => {
    if (search && !p.filename.toLowerCase().includes(search.toLowerCase())) return false
    if (filter === 'hasFace' && p.faceCount === 0) return false
    if (filter === 'noFace' && p.faceCount > 0) return false
    return true
  })

  const toggleSelect = (id: string) => {
    setSelected((prev) => {
      const next = new Set(prev)
      next.has(id) ? next.delete(id) : next.add(id)
      return next
    })
  }

  const openLightbox = (index: number) => setLightboxIndex(index)
  const closeLightbox = () => setLightboxIndex(null)

  if (isLoading) return <div className={styles.container}><p>加载照片中...</p></div>
  if (!photos?.length) return <div className={styles.container}><div className={styles.empty}>暂无照片</div></div>

  return (
    <div className={styles.container}>
      <div className={styles.toolbar}>
        <div className={styles.searchBox}>
          <input
            type="text"
            className={styles.searchInput}
            placeholder="搜索文件名..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
        <select className={styles.filterSelect} value={filter} onChange={(e) => setFilter(e.target.value)}>
          {FILTER_OPTIONS.map((opt) => (
            <option key={opt.value} value={opt.value}>{opt.label}</option>
          ))}
        </select>
      </div>
      {selected.size > 0 && (
        <div className={styles.selectionBar}>
          选中 {selected.size} 张照片
          <button className={styles.clearBtn} onClick={() => setSelected(new Set())}>取消选择</button>
        </div>
      )}
      <div className={styles.grid}>
        {filtered.map((photo, idx) => (
          <GalleryThumbnail
            key={photo.id}
            photo={photo}
            isSelected={selected.has(photo.id)}
            onSelect={() => toggleSelect(photo.id)}
            onClick={() => openLightbox(idx)}
          />
        ))}
      </div>
      {lightboxIndex !== null && filtered.length > 0 && (
        <Lightbox
          photos={filtered}
          initialIndex={lightboxIndex}
          onClose={closeLightbox}
        />
      )}
    </div>
  )
}

function GalleryThumbnail({ photo, isSelected, onSelect, onClick }: {
  photo: PhotoData
  isSelected: boolean
  onSelect: () => void
  onClick: () => void
}) {
  const [src, setSrc] = useState<string | null>(null)
  const [hasError, setHasError] = useState(false)
  const loadedRef = useRef(false)
  const imgRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const el = imgRef.current
    if (!el) return
    loadedRef.current = false
    setHasError(false)
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting && !loadedRef.current) {
          loadedRef.current = true
          imageApi.getThumbnail(photo.filepath, 320).then((r) => {
            setSrc(`data:image/jpeg;base64,${r.buffer}`)
          }).catch((err) => {
            console.error('[Gallery] thumbnail load failed:', photo.filepath, err)
            setHasError(true)
          })
        }
      },
      { rootMargin: '200px' },
    )
    observer.observe(el)
    return () => observer.disconnect()
  }, [photo.filepath])

  return (
    <div
      ref={imgRef}
      className={`${styles.thumb} ${isSelected ? styles.thumbSelected : ''}`}
      onClick={(e) => {
        if (e.ctrlKey || e.metaKey) {
          onSelect()
        } else {
          onClick()
        }
      }}
    >
      {src ? (
        <img src={src} alt={photo.filename} className={styles.thumbImg} loading="lazy" />
      ) : hasError ? (
        <div className={styles.thumbError}>
          <span className={styles.thumbErrorIcon}>!</span>
          <span className={styles.thumbErrorPath}>{photo.filename}</span>
        </div>
      ) : (
        <div className={styles.thumbPlaceholder} />
      )}
      <div className={styles.thumbName}>{photo.filename}</div>
      {isSelected && <div className={styles.thumbCheck}>✓</div>}
    </div>
  )
}
