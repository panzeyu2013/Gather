import React, { useState, useEffect, useMemo, useCallback, useRef, useDeferredValue, memo } from 'react'
import { useParams } from 'react-router-dom'
import { useInfiniteQuery, useQueryClient, type InfiniteData } from '@tanstack/react-query'
import { sessionApi } from '../../api/session'
import { imageApi } from '../../api/image'
import { useSessionStore } from '../../stores/sessionStore'
import { useSettingsStore } from '../../stores/settingsStore'
import Lightbox from '../../components/Lightbox/Lightbox'
import { layoutJustifiedRows } from './justified-layout'
import type { PhotoData } from '@gather/shared'
import { useTranslation, type TranslationKey } from '../../locales'
import styles from './Gallery.module.css'

const PAGE_SIZE = 200

const FILTER_OPTIONS: Array<{ value: string; labelKey: TranslationKey }> = [
  { value: 'all', labelKey: 'gallery.filterAll' },
  { value: 'hasFace', labelKey: 'gallery.filterHasFace' },
  { value: 'noFace', labelKey: 'gallery.filterNoFace' },
]

const DENSITY_OPTIONS: Array<{ value: number; labelKey: TranslationKey }> = [
  { value: 160, labelKey: 'gallery.densitySmall' },
  { value: 220, labelKey: 'gallery.densityMedium' },
  { value: 300, labelKey: 'gallery.densityLarge' },
]

export default function Gallery() {
  const { t } = useTranslation()
  const { sessionId } = useParams<{ sessionId: string }>()
  const setSession = useSessionStore((s) => s.setSession)
  const queryClient = useQueryClient()

  const [search, setSearch] = useState('')
  const deferredSearch = useDeferredValue(search)
  const [filter, setFilter] = useState('all')
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null)
  const [density, setDensity] = useState(220)
  const [expandVariants, setExpandVariants] = useState(false)
  const [galleryWidth, setGalleryWidth] = useState(0)
  const [galleryHeight, setGalleryHeight] = useState(0)
  const [scrollTop, setScrollTop] = useState(0)
  const galleryRef = useRef<HTMLDivElement | null>(null)
  const scrollFrameRef = useRef<number | null>(null)

  const thumbnailSizeSetting = useSettingsStore((s) => s.settings['thumbnail_size'])
  const settingsLoaded = useSettingsStore((s) => Object.keys(s.settings).length > 0)
  const loadSettings = useSettingsStore((s) => s.load)
  const configuredThumbSize = parseInt(thumbnailSizeSetting ?? '1024', 10)
  const thumbSize = configuredThumbSize <= 320
    ? 256
    : configuredThumbSize <= 1280
      ? 1024
      : 2048

  useEffect(() => {
    if (!settingsLoaded) loadSettings()
  }, [loadSettings, settingsLoaded])

  // Searching or filtering must see the whole session, not just the pages
  // loaded so far: the chain-fetch effect below pulls every remaining page.
  const searchActive = deferredSearch.trim() !== '' || filter !== 'all'

  const { data: photos, isLoading, isFetchingNextPage, hasNextPage, fetchNextPage } = useInfiniteQuery({
    queryKey: ['photos', sessionId, expandVariants],
    queryFn: ({ pageParam }) => sessionApi.getPhotosPage(sessionId!, {
      afterFirstRowid: pageParam as number | undefined,
      // Searching/filtering chain-fetches the whole session; larger pages
      // cut the number of sequential round trips (200 -> ~100 for 100k).
      limit: searchActive ? 1000 : PAGE_SIZE,
      expandVariants,
    }),
    initialPageParam: undefined as number | undefined,
    getNextPageParam: (lastPage) => lastPage.cursor ?? undefined,
    enabled: !!sessionId,
  })
  const loadedPhotos = useMemo(
    () => (photos?.pages ?? []).flatMap(page => page.rows),
    [photos],
  )

  useEffect(() => {
    if (sessionId) setSession(sessionId)
  }, [sessionId, setSession])

  const filtered = useMemo(() => (loadedPhotos ?? []).filter((p) => {
    if (deferredSearch && !p.filename.toLowerCase().includes(deferredSearch.toLowerCase())) return false
    if (filter === 'hasFace' && p.faceCount === 0) return false
    if (filter === 'noFace' && p.faceCount > 0) return false
    return true
  }), [loadedPhotos, deferredSearch, filter])

  // Load more pages as the user scrolls to the bottom. The sentinel lives
  // below the virtual canvas; an observer on it triggers the next keyset
  // page while the first page is still rendering.
  const sentinelRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const element = sentinelRef.current
    if (!element) return
    if (typeof IntersectionObserver === 'undefined') return
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some(entry => entry.isIntersecting)) {
          void fetchNextPage()
        }
      },
      { rootMargin: '1600px' },
    )
    observer.observe(element)
    return () => observer.disconnect()
  }, [fetchNextPage, hasNextPage])

  // Searching or filtering must see the whole session, not just the pages
  // loaded so far: chain-fetch every remaining page while a filter is active.
  useEffect(() => {
    if (!searchActive) return
    if (!hasNextPage || isFetchingNextPage) return
    void fetchNextPage()
  }, [searchActive, hasNextPage, isFetchingNextPage, fetchNextPage])

  // Exiting search/filter drops the chain-fetched extra pages from the query
  // cache: while a filter was active the effect above pulled every remaining
  // page (100k+ rows for a big session), and clearing it must release them
  // instead of keeping them held for the rest of the session. The first page
  // is retained so the view does not flash empty; the sentinel resumes
  // natural pagination from there. Search-time fetching behavior is untouched.
  const searchActiveRef = useRef(false)
  useEffect(() => {
    if (searchActiveRef.current === searchActive) return
    searchActiveRef.current = searchActive
    if (searchActive || !sessionId) return
    queryClient.setQueryData<InfiniteData<{ rows: PhotoData[]; cursor: number | null }>>(
      ['photos', sessionId, expandVariants],
      (data) => {
        if (!data || data.pages.length <= 1) return data
        return {
          ...data,
          pages: data.pages.slice(0, 1),
          pageParams: data.pageParams.slice(0, 1),
        }
      },
    )
  }, [expandVariants, queryClient, searchActive, sessionId])

  const resizeObserverRef = useRef<ResizeObserver | null>(null)

  // Stable measurement callback: reads the element through the ref so the
  // observer survives page-load re-renders instead of being rebuilt on every
  // fetched page.
  const measureGallery = useCallback(() => {
    const element = galleryRef.current
    if (!element) return
    setGalleryWidth((current) => (
      current === element.clientWidth ? current : element.clientWidth
    ))
    setGalleryHeight((current) => (
      current === element.clientHeight ? current : element.clientHeight
    ))
  }, [])

  // The grid only mounts once the first page resolves, so the observer is
  // attached via a callback ref: it runs exactly when the element appears
  // (and detaches when it unmounts) instead of re-observing on every load.
  const attachGalleryResize = useCallback((element: HTMLDivElement | null) => {
    galleryRef.current = element
    if (typeof ResizeObserver === 'undefined') {
      if (element) {
        measureGallery()
        window.addEventListener('resize', measureGallery)
      } else {
        window.removeEventListener('resize', measureGallery)
      }
      return
    }
    if (resizeObserverRef.current) {
      resizeObserverRef.current.disconnect()
      resizeObserverRef.current = null
    }
    if (!element) return
    const observer = new ResizeObserver(measureGallery)
    resizeObserverRef.current = observer
    observer.observe(element)
    measureGallery()
  }, [measureGallery])

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
      if (next.has(id)) {
        next.delete(id)
      } else {
        next.add(id)
      }
      return next
    })
  }

  const openLightbox = useCallback((index: number) => {
    setLightboxIndex(index)
  }, [])

  const closeLightbox = () => setLightboxIndex(null)

  if (isLoading) return <div className={styles.container}><p>{t('gallery.loading')}</p></div>
  if (!loadedPhotos?.length) return <div className={styles.container}><div className={styles.empty}>{t('gallery.empty')}</div></div>

  return (
    <div className={styles.container}>
      <div className={styles.toolbar}>
        <div className={styles.searchBox}>
          <input
            type="text"
            className={styles.searchInput}
            placeholder={t('gallery.searchPlaceholder')}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>
        <select className={styles.filterSelect} value={filter} onChange={(e) => setFilter(e.target.value)}>
          {FILTER_OPTIONS.map((opt) => (
            <option key={opt.value} value={opt.value}>{t(opt.labelKey)}</option>
          ))}
        </select>
        <select className={styles.filterSelect} value={density} onChange={(e) => setDensity(Number(e.target.value))}>
          {DENSITY_OPTIONS.map((opt) => (
            <option key={opt.value} value={opt.value}>{t(opt.labelKey)}</option>
          ))}
        </select>
        <button
          className={styles.variantToggle}
          aria-pressed={expandVariants}
          onClick={() => setExpandVariants(value => !value)}
        >
          {expandVariants ? t('gallery.collapseVariants') : t('gallery.expandVariants')}
        </button>
      </div>
      {selected.size > 0 && (
        <div className={styles.selectionBar}>
          {t('gallery.selectedCount', { count: selected.size })}
          <button className={styles.clearBtn} onClick={() => setSelected(new Set())}>{t('gallery.clearSelection')}</button>
        </div>
      )}
      <div
        ref={attachGalleryResize}
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
                  <button
                    key={photo.id}
                    type="button"
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
                  </button>
                )
              })}
            </div>
          ))}
        </div>
        <div ref={sentinelRef} className={styles.loadMore}>
          {isFetchingNextPage ? <span className={styles.loadMoreText}>{t('gallery.loadMore')}</span> : null}
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

const GalleryThumbnail = memo(function GalleryThumbnail({ photo, isSelected, thumbSize }: {
  photo: PhotoData
  isSelected: boolean
  thumbSize: number
}) {
  const { t } = useTranslation()
  const [src, setSrc] = useState<string | null>(null)
  const [hasError, setHasError] = useState(false)
  const [shouldLoad, setShouldLoad] = useState(false)
  const containerRef = useRef<HTMLSpanElement>(null)

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
    <span ref={containerRef} className={styles.thumb}>
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
        <span className={styles.thumbError}>
          <span className={styles.thumbErrorIcon}>!</span>
          <span className={styles.thumbErrorPath}>{photo.filename}</span>
        </span>
      ) : (
        <span className={styles.thumbPlaceholder} />
      )}
      <span className={styles.thumbName}>{photo.filename}</span>
      {(photo.variantCount ?? 1) > 1 && (
        <span className={styles.variantBadge}>{t('gallery.variantBadge', { count: photo.variantCount })}</span>
      )}
      {isSelected && <span className={styles.thumbCheck}>✓</span>}
    </span>
  )
})
