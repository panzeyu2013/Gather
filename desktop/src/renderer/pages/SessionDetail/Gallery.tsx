import React, { useState, useEffect, useMemo, useCallback } from 'react'
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

const DENSITY_OPTIONS = [
  { value: 160, label: '小图' },
  { value: 220, label: '中图' },
  { value: 300, label: '大图' },
]

function getAspectRatio(p: { width: number; height: number }): number {
  if (p.width > 0 && p.height > 0) return p.width / p.height
  return 1
}

export default function Gallery() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const setSession = useSessionStore((s) => s.setSession)

  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState('all')
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null)
  const [density, setDensity] = useState(220)
  const [dims, setDims] = useState<Record<string, { width: number; height: number }>>({})
  const [imgDims, setImgDims] = useState<Record<string, { width: number; height: number }>>({})

  const handleThumbLoad = useCallback((filepath: string, width: number, height: number) => {
    setImgDims((prev) => {
      if (prev[filepath]?.width === width && prev[filepath]?.height === height) return prev
      return { ...prev, [filepath]: { width, height } }
    })
  }, [])

  const { data: photos, isLoading } = useQuery({
    queryKey: ['photos', sessionId],
    queryFn: () => sessionApi.getPhotos(sessionId!),
    enabled: !!sessionId,
  })

  useEffect(() => {
    if (sessionId) setSession(sessionId)
  }, [sessionId, setSession])

  useEffect(() => {
    if (photos && photos.length > 0) {
      const filepaths = photos.map((p) => p.filepath)
      imageApi.preloadThumbnails(filepaths, 320).catch(() => {})

      imageApi.getDimensions(filepaths).then((result) => {
        setDims((prev) => ({ ...prev, ...result }))
      }).catch(() => {})
    }
  }, [photos])

  const enrichedPhotos = useMemo(() => {
    if (!photos) return []
    return photos.map((p) => {
      const d = dims[p.filepath]
      if (d && d.width > 0 && d.height > 0) return { ...p, width: d.width, height: d.height }
      return p
    })
  }, [photos, dims])

  const filtered = useMemo(() => enrichedPhotos.filter((p) => {
    if (search && !p.filename.toLowerCase().includes(search.toLowerCase())) return false
    if (filter === 'hasFace' && p.faceCount === 0) return false
    if (filter === 'noFace' && p.faceCount > 0) return false
    return true
  }), [enrichedPhotos, search, filter])

  const toggleSelect = (id: string) => {
    setSelected((prev) => {
      const next = new Set(prev)
      next.has(id) ? next.delete(id) : next.add(id)
      return next
    })
  }

  const openLightbox = useCallback((index: number, photo: PhotoData) => {
    imageApi.prioritizeThumbnail(photo.filepath)
    setLightboxIndex(index)
  }, [])

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
        <select className={styles.filterSelect} value={density} onChange={(e) => setDensity(Number(e.target.value))}>
          {DENSITY_OPTIONS.map((opt) => (
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
      <div
        className={styles.grid}
        style={{ gridTemplateColumns: `repeat(auto-fill, minmax(${density}px, 1fr))` }}
      >
        {filtered.map((photo, index) => {
          const ar = getAspectRatio(imgDims[photo.filepath] ?? photo)
          return (
            <div
              key={photo.id}
              className={`${styles.cell} ${selected.has(photo.id) ? styles.cellSelected : ''}`}
              style={{ paddingBottom: `${100 / ar}%` }}
              onClick={(e) => {
                if (e.ctrlKey || e.metaKey) {
                  toggleSelect(photo.id)
                } else {
                  openLightbox(index, photo)
                }
              }}
            >
              <GalleryThumbnail
                photo={photo}
                isSelected={selected.has(photo.id)}
                onLoad={handleThumbLoad}
              />
            </div>
          )
        })}
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

function GalleryThumbnail({ photo, isSelected, onLoad }: {
  photo: PhotoData
  isSelected: boolean
  onLoad: (filepath: string, width: number, height: number) => void
}) {
  const [src, setSrc] = useState<string | null>(null)
  const [hasError, setHasError] = useState(false)

  useEffect(() => {
    let cancelled = false
    imageApi.getThumbnail(photo.filepath, 320)
      .then((r) => {
        if (!cancelled) setSrc(`data:image/jpeg;base64,${r.buffer}`)
      })
      .catch((err) => {
        if (!cancelled) {
          console.error('[Gallery] thumbnail load failed:', photo.filepath, err)
          setHasError(true)
        }
      })
    return () => { cancelled = true }
  }, [photo.filepath])

  return (
    <div className={styles.thumb}>
      {src ? (
        <img
          src={src}
          alt={photo.filename}
          className={styles.thumbImg}
          loading="lazy"
          onLoad={(e) => onLoad(photo.filepath, e.currentTarget.naturalWidth, e.currentTarget.naturalHeight)}
        />
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
