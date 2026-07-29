import React, { useState, useEffect, useMemo, useCallback, useRef } from 'react'
import { useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { sessionApi } from '../../api/session'
import { imageApi } from '../../api/image'
import { useSessionStore } from '../../stores/sessionStore'
import { useSettingsStore } from '../../stores/settingsStore'
import Lightbox from '../../components/Lightbox/Lightbox'
import { layoutJustifiedRows } from './justified-layout'
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

export default function Gallery() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const setSession = useSessionStore((s) => s.setSession)

  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState('all')
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null)
  const [density, setDensity] = useState(220)
  const [galleryWidth, setGalleryWidth] = useState(0)
  const [galleryHeight, setGalleryHeight] = useState(0)
  const [scrollTop, setScrollTop] = useState(0)
  const galleryRef = useRef<HTMLDivElement>(null)
  const scrollFrameRef = useRef<number | null>(null)

  const settings = useSettingsStore((s) => s.settings)
  const loadSettings = useSettingsStore((s) => s.load)
  const configuredThumbSize = parseInt(settings['thumbnail_size'] ?? '1024', 10)
  const thumbSize = configuredThumbSize <= 320
    ? 256
    : configuredThumbSize <= 1280
      ? 1024
      : 2048

  useEffect(() => {
    if (Object.keys(settings).length === 0) loadSettings()
  }, [loadSettings])

  const { data: photos, isLoading } = useQuery({
    queryKey: ['photos', sessionId],
    queryFn: () => sessionApi.getPhotos(sessionId!),
    enabled: !!sessionId,
  })

  useEffect(() => {
    if (sessionId) setSession(sessionId)
  }, [sessionId, setSession])

  const filtered = useMemo(() => (photos ?? []).filter((p) => {
    if (search && !p.filename.toLowerCase().includes(search.toLowerCase())) return false
    if (filter === 'hasFace' && p.faceCount === 0) return false
    if (filter === 'noFace' && p.faceCount > 0) return false
    return true
  }), [photos, search, filter])

  useEffect(() => {
    const element = galleryRef.current
    if (!element) return

    const updateWidth = () => {
      setGalleryWidth((current) => (
        current === element.clientWidth ? current : element.clientWidth
      ))
      setGalleryHeight((current) => (
        current === element.clientHeight ? current : element.clientHeight
      ))
    }
    updateWidth()

    if (typeof ResizeObserver === 'undefined') {
      window.addEventListener('resize', updateWidth)
      return () => window.removeEventListener('resize', updateWidth)
    }

    const observer = new ResizeObserver(updateWidth)
    observer.observe(element)
    return () => observer.disconnect()
  }, [isLoading, photos?.length])

  const rows = useMemo(
    () => layoutJustifiedRows(filtered, galleryWidth, density, 8),
    [density, filtered, galleryWidth],
  )
  const rowMetrics = useMemo(() => {
    let top = 0
    const metrics = rows.map((row, index) => {
      const metric = { row, index, top, bottom: top + row.height }
      top += row.height + (index === rows.length - 1 ? 0 : 8)
      return metric
    })
    return { metrics, totalHeight: top }
  }, [rows])
  const visibleRows = useMemo(() => {
    const overscan = Math.max(600, galleryHeight)
    const visibleTop = Math.max(0, scrollTop - overscan)
    const visibleBottom = scrollTop + galleryHeight + overscan
    return rowMetrics.metrics.filter(
      (metric) => metric.bottom >= visibleTop && metric.top <= visibleBottom,
    )
  }, [galleryHeight, rowMetrics, scrollTop])

  useEffect(() => {
    const maximum = Math.max(0, rowMetrics.totalHeight - galleryHeight)
    if (scrollTop <= maximum) return
    if (galleryRef.current) galleryRef.current.scrollTop = maximum
    setScrollTop(maximum)
  }, [galleryHeight, rowMetrics.totalHeight, scrollTop])

  useEffect(() => () => {
    if (scrollFrameRef.current !== null) {
      cancelAnimationFrame(scrollFrameRef.current)
    }
  }, [])

  const handleScroll = useCallback((event: React.UIEvent<HTMLDivElement>) => {
    const nextScrollTop = event.currentTarget.scrollTop
    if (scrollFrameRef.current !== null) cancelAnimationFrame(scrollFrameRef.current)
    scrollFrameRef.current = requestAnimationFrame(() => {
      setScrollTop(nextScrollTop)
      scrollFrameRef.current = null
    })
  }, [])

  const toggleSelect = (id: string) => {
    setSelected((prev) => {
      const next = new Set(prev)
      next.has(id) ? next.delete(id) : next.add(id)
      return next
    })
  }

  const openLightbox = useCallback((index: number) => {
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
        ref={galleryRef}
        className={styles.grid}
        onScroll={handleScroll}
      >
        <div className={styles.virtualCanvas} style={{ height: rowMetrics.totalHeight }}>
          {visibleRows.map(({ row, index: rowIndex, top }) => (
            <div
              key={`${row.items[0]?.index ?? 'empty'}-${rowIndex}`}
              className={styles.row}
              style={{ height: row.height, transform: `translateY(${top}px)` }}
            >
              {row.items.map((layoutItem) => {
                const photo = filtered[layoutItem.index]
                return (
                  <div
                    key={photo.id}
                    className={`${styles.cell} ${selected.has(photo.id) ? styles.cellSelected : ''}`}
                    style={{ width: layoutItem.width, height: row.height }}
                    onClick={(e) => {
                      if (e.ctrlKey || e.metaKey) {
                        toggleSelect(photo.id)
                      } else {
                        openLightbox(layoutItem.index)
                      }
                    }}
                  >
                    <GalleryThumbnail
                      photo={photo}
                      isSelected={selected.has(photo.id)}
                      thumbSize={thumbSize}
                    />
                  </div>
                )
              })}
            </div>
          ))}
        </div>
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

function GalleryThumbnail({ photo, isSelected, thumbSize }: {
  photo: PhotoData
  isSelected: boolean
  thumbSize: number
}) {
  const [src, setSrc] = useState<string | null>(null)
  const [hasError, setHasError] = useState(false)
  const [shouldLoad, setShouldLoad] = useState(false)
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const element = containerRef.current
    if (!element) return
    if (typeof IntersectionObserver === 'undefined') {
      setShouldLoad(true)
      return
    }

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          setShouldLoad(true)
          observer.disconnect()
        }
      },
      { rootMargin: '800px' },
    )
    observer.observe(element)
    return () => observer.disconnect()
  }, [photo.filepath])

  useEffect(() => {
    if (!shouldLoad) return
    setSrc(imageApi.thumbnailUrl(photo.filepath, thumbSize))
    setHasError(false)
  }, [photo.filepath, shouldLoad, thumbSize])

  return (
    <div ref={containerRef} className={styles.thumb}>
      {src ? (
        <img
          src={src}
          alt={photo.filename}
          className={styles.thumbImg}
          loading="lazy"
          onError={() => {
            setSrc(null)
            setHasError(true)
          }}
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
