import React, { useState, useEffect, useCallback, useRef } from 'react'
import { imageApi } from '../../api/image'
import type { PhotoData } from '@gather/shared'
import { useTranslation } from '../../locales'
import styles from './Lightbox.module.css'

interface LightboxProps {
  photos: PhotoData[]
  initialIndex: number
  onClose: () => void
}

export default function Lightbox({ photos, initialIndex, onClose }: LightboxProps) {
  const { t } = useTranslation()
  const [index, setIndex] = useState(initialIndex)
  const [scale, setScale] = useState(1)
  const [position, setPosition] = useState({ x: 0, y: 0 })
  const [dragging, setDragging] = useState(false)
  const [dragStart, setDragStart] = useState({ x: 0, y: 0 })
  const [src, setSrc] = useState<string | null>(null)
  const [loadError, setLoadError] = useState(false)
  const containerRef = useRef<HTMLDivElement>(null)
  const rafRef = useRef<number | null>(null)
  const pendingPositionRef = useRef({ x: 0, y: 0 })
  const pendingScaleRef = useRef(1)

  const photo = photos[index]

  // Coalesce mousemove position updates into one setPosition per frame so a
  // drag does not trigger a render on every pointer move.
  useEffect(() => () => {
    if (rafRef.current != null) cancelAnimationFrame(rafRef.current)
  }, [])

  const goNext = useCallback(() => {
    if (index < photos.length - 1) setIndex(index + 1)
  }, [index, photos.length])

  const goPrev = useCallback(() => {
    if (index > 0) setIndex(index - 1)
  }, [index])

  // Coalesce wheel zoom updates into one setScale per frame, same rAF pattern
  // as the position coalescing below: high-frequency wheel events write the
  // latest clamped value into a ref and a single pending frame commits it.
  const handleWheel = useCallback((e: WheelEvent) => {
    e.preventDefault()
    pendingScaleRef.current = Math.max(
      0.5,
      Math.min(5, pendingScaleRef.current + (e.deltaY > 0 ? -0.2 : 0.2)),
    )
    if (rafRef.current != null) return
    rafRef.current = requestAnimationFrame(() => {
      rafRef.current = null
      setScale(pendingScaleRef.current)
    })
  }, [])

  // `photos` is deliberately not a dependency: the Gallery chain-fetches and
  // re-filters while the lightbox is open, so an unrelated photos-array change
  // must not reset the zoom, pan position, or image src mid-viewing. Only the
  // active photo (index + filepath) triggers a reload; the adjacent preload
  // is best-effort and reads the current photos array when it runs.
  useEffect(() => {
    if (!photo) return
    setLoadError(false)
    setScale(1)
    // Keep the wheel accumulator in sync with the committed reset so a pending
    // or future wheel event resumes from 1x instead of the previous zoom.
    pendingScaleRef.current = 1
    setPosition({ x: 0, y: 0 })
    const viewportDimension = Math.max(window.innerWidth, window.innerHeight)
    const maxDimension = Math.max(
      2048,
      Math.min(5120, Math.ceil(viewportDimension * window.devicePixelRatio)),
    )
    setSrc(imageApi.previewUrl(photo.filepath, maxDimension))
    const adjacentPaths = [photos[index - 1]?.filepath, photos[index + 1]?.filepath]
      .filter((path): path is string => Boolean(path))
    void imageApi.preloadPreviews(adjacentPaths, maxDimension).catch(() => {
      // Prefetch is best-effort; the foreground request still reports errors.
    })
  }, [index, photo?.filepath])

  useEffect(() => {
    const handleKey = (e: KeyboardEvent) => {
      switch (e.key) {
        case 'Escape': onClose(); break
        case 'ArrowRight': goNext(); break
        case 'ArrowLeft': goPrev(); break
      }
    }
    window.addEventListener('keydown', handleKey)
    return () => window.removeEventListener('keydown', handleKey)
  }, [onClose, goNext, goPrev])

  useEffect(() => {
    const el = containerRef.current
    if (!el) return
    el.addEventListener('wheel', handleWheel, { passive: false })
    return () => el.removeEventListener('wheel', handleWheel)
  }, [handleWheel])

  const handleMouseDown = (e: React.MouseEvent) => {
    if (scale <= 1) return
    setDragging(true)
    setDragStart({ x: e.clientX - position.x, y: e.clientY - position.y })
  }

  const handleMouseMove = (e: React.MouseEvent) => {
    if (!dragging) return
    pendingPositionRef.current = { x: e.clientX - dragStart.x, y: e.clientY - dragStart.y }
    if (rafRef.current != null) return
    rafRef.current = requestAnimationFrame(() => {
      rafRef.current = null
      setPosition(pendingPositionRef.current)
    })
  }

  const handleMouseUp = () => setDragging(false)

  if (!photo) return null

  return (
    <div className={styles.overlay} onClick={onClose}>
      <div className={styles.header}>
        <span className={styles.counter}>{index + 1} / {photos.length}</span>
        <span className={styles.filename}>{photo.filename}</span>
        <span className={styles.zoom}>{Math.round(scale * 100)}%</span>
        <button className={styles.closeBtn} onClick={onClose}>✕</button>
      </div>
      <button className={styles.navBtn} style={{ left: 16 }} onClick={(e) => { e.stopPropagation(); goPrev() }} disabled={index === 0}>
        ‹
      </button>
      <div
        ref={containerRef}
        className={styles.content}
        onClick={(e) => e.stopPropagation()}
        onMouseDown={handleMouseDown}
        onMouseMove={handleMouseMove}
        onMouseUp={handleMouseUp}
        onMouseLeave={handleMouseUp}
        style={{ cursor: scale > 1 ? (dragging ? 'grabbing' : 'grab') : 'default' }}
      >
        {src ? (
          <img
          src={src}
            alt={photo.filename}
            className={styles.image}
          draggable={false}
          onError={() => {
            setSrc(null)
            setLoadError(true)
          }}
            style={{
              transform: `translate(${position.x}px, ${position.y}px) scale(${scale})`,
              transformOrigin: 'center center',
            }}
          />
        ) : loadError ? (
          <div className={styles.error}>{t('lightbox.loadFailed')}</div>
        ) : (
          <div className={styles.loading}>{t('lightbox.loading')}</div>
        )}
      </div>
      <button className={styles.navBtn} style={{ right: 16 }} onClick={(e) => { e.stopPropagation(); goNext() }} disabled={index >= photos.length - 1}>
        ›
      </button>
    </div>
  )
}
