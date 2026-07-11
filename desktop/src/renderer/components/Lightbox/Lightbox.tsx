import React, { useState, useEffect, useCallback, useRef } from 'react'
import { imageApi } from '../../api/image'
import type { PhotoData } from '@gather/shared'
import styles from './Lightbox.module.css'

interface LightboxProps {
  photos: PhotoData[]
  initialIndex: number
  onClose: () => void
}

export default function Lightbox({ photos, initialIndex, onClose }: LightboxProps) {
  const [index, setIndex] = useState(initialIndex)
  const [scale, setScale] = useState(1)
  const [position, setPosition] = useState({ x: 0, y: 0 })
  const [dragging, setDragging] = useState(false)
  const [dragStart, setDragStart] = useState({ x: 0, y: 0 })
  const [src, setSrc] = useState<string | null>(null)
  const containerRef = useRef<HTMLDivElement>(null)

  const photo = photos[index]

  const goNext = useCallback(() => {
    if (index < photos.length - 1) setIndex(index + 1)
  }, [index, photos.length])

  const goPrev = useCallback(() => {
    if (index > 0) setIndex(index - 1)
  }, [index])

  const handleWheel = useCallback((e: WheelEvent) => {
    e.preventDefault()
    setScale((prev) => Math.max(0.5, Math.min(5, prev + (e.deltaY > 0 ? -0.2 : 0.2))))
  }, [])

  useEffect(() => {
    let cancelled = false
    if (!photo) return
    setSrc(null)
    setScale(1)
    setPosition({ x: 0, y: 0 })
    imageApi.getPreview(photo.filepath, 1920).then((r) => {
      if (cancelled) return
      setSrc(`data:image/jpeg;base64,${r.buffer}`)
    }).catch(() => {})
    return () => { cancelled = true }
  }, [photo?.filepath])

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
    setPosition({ x: e.clientX - dragStart.x, y: e.clientY - dragStart.y })
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
            style={{
              transform: `translate(${position.x}px, ${position.y}px) scale(${scale})`,
              transformOrigin: 'center center',
            }}
          />
        ) : (
          <div className={styles.loading}>加载中...</div>
        )}
      </div>
      <button className={styles.navBtn} style={{ right: 16 }} onClick={(e) => { e.stopPropagation(); goNext() }} disabled={index >= photos.length - 1}>
        ›
      </button>
    </div>
  )
}
