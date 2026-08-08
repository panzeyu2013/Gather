import React, { useEffect, useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { filterApi, albumApi } from '../../api/filter'
import { assetApi } from '../../api/assets'
import { sessionApi } from '../../api/session'
import { imageApi } from '../../api/image'
import { metadataApi } from '../../api/metadata'
import type { FilterGroup, FilterRule } from '@gather/shared'
import { useTranslation } from '../../locales'
import { translateError, translateErrorCode } from '../../utils/errors'
import styles from './Library.module.css'

const PAGE_SIZE = 60
const COLOR_LABELS = ['', 'Red', 'Orange', 'Yellow', 'Green', 'Blue', 'Pink', 'Purple']

// Delays criteria propagation: the four free-text filters would otherwise
// trigger a new IPC query on every keystroke.
function useDebouncedValue<T>(value: T, delay = 300): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delay)
    return () => clearTimeout(timer)
  }, [value, delay])
  return debounced
}

function buildCriteria(
  search: string,
  rating: string,
  label: string,
  status: string,
  keyword: string,
  directory: string,
  volume: string,
  person: string,
  duplicates: string,
  recentDays: string,
): FilterGroup {
  const conditions: FilterRule[] = []
  if (search.trim()) conditions.push({ field: 'filename', operator: 'contains', value: search.trim() })
  if (rating) conditions.push({ field: 'rating', operator: 'gte', value: Number(rating) })
  if (label) conditions.push({ field: 'label', operator: 'eq', value: label })
  if (status) {
    conditions.push({
      field: 'status',
      operator: status === 'online' ? 'neq' : 'eq',
      value: 'missing',
    })
  }
  if (keyword.trim()) {
    conditions.push({ field: 'keywords', operator: 'contains_any', value: [keyword.trim()] })
  }
  if (directory.trim()) {
    conditions.push({ field: 'directory', operator: 'starts_with', value: directory.trim() })
  }
  if (volume) conditions.push({ field: 'volume', operator: 'eq', value: volume })
  if (person.trim()) conditions.push({ field: 'person', operator: 'contains', value: person.trim() })
  if (duplicates) {
    conditions.push({ field: 'has_duplicates', operator: 'eq', value: duplicates === 'yes' })
  }
  if (recentDays) {
    const since = new Date(Date.now() - Number(recentDays) * 86_400_000).toISOString()
    conditions.push({ field: 'created_at', operator: 'gte', value: since })
  }
  return { logic: 'and', conditions }
}

export default function Library() {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const [sessionFilter, setSessionFilter] = useState('')
  const [search, setSearch] = useState('')
  const [rating, setRating] = useState('')
  const [label, setLabel] = useState('')
  const [status, setStatus] = useState('')
  const [keyword, setKeyword] = useState('')
  const [directory, setDirectory] = useState('')
  const [volume, setVolume] = useState('')
  const [person, setPerson] = useState('')
  const [duplicates, setDuplicates] = useState('')
  const [recentDays, setRecentDays] = useState('')
  const [albumName, setAlbumName] = useState('')
  const [selectedAlbum, setSelectedAlbum] = useState<string>()
  const [page, setPage] = useState(0)
  const debouncedSearch = useDebouncedValue(search)
  const debouncedKeyword = useDebouncedValue(keyword)
  const debouncedDirectory = useDebouncedValue(directory)
  const debouncedPerson = useDebouncedValue(person)
  const criteria = useMemo(
    () => buildCriteria(
      debouncedSearch,
      rating,
      label,
      status,
      debouncedKeyword,
      debouncedDirectory,
      volume,
      debouncedPerson,
      duplicates,
      recentDays,
    ),
    [debouncedDirectory, debouncedKeyword, debouncedPerson, debouncedSearch, duplicates, label, rating, recentDays, status, volume],
  )
  const criteriaKey = JSON.stringify(criteria)

  useEffect(() => setPage(0), [criteriaKey, selectedAlbum, sessionFilter])

  const { data: sessions = [] } = useQuery({
    queryKey: ['sessions'],
    queryFn: sessionApi.list,
  })
  const { data: photoResult, isLoading, isError, error, refetch } = useQuery({
    queryKey: ['library', 'photos', selectedAlbum, criteriaKey, sessionFilter, page],
    queryFn: () => selectedAlbum
      ? albumApi.getPhotos(selectedAlbum, PAGE_SIZE, page * PAGE_SIZE)
      : filterApi.photosGlobal(criteria, {
        sessionId: sessionFilter || undefined,
        limit: PAGE_SIZE,
        offset: page * PAGE_SIZE,
      }),
  })
  const photos = photoResult?.photos ?? []
  const total = photoResult?.total ?? 0
  const { data: albums = [] } = useQuery({ queryKey: ['albums'], queryFn: albumApi.list })
  const { data: linkCandidates = [] } = useQuery({
    queryKey: ['asset-link-candidates'],
    queryFn: assetApi.candidates,
  })
  const { data: metadataOrphans = [] } = useQuery({
    queryKey: ['metadata-orphans'],
    queryFn: metadataApi.orphans,
  })
  const { data: volumes = [] } = useQuery({
    queryKey: ['asset-volumes'],
    queryFn: assetApi.volumes,
  })

  const createAlbum = useMutation({
    mutationFn: () => albumApi.create({ name: albumName.trim(), criteria }),
    onSuccess: () => {
      setAlbumName('')
      queryClient.invalidateQueries({ queryKey: ['albums'] })
    },
  })
  const updateAlbum = useMutation({
    mutationFn: () => albumApi.update(selectedAlbum!, { criteria }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['albums'] })
      queryClient.invalidateQueries({ queryKey: ['library', 'photos'] })
    },
  })
  const deleteAlbum = useMutation({
    mutationFn: (id: string) => albumApi.delete(id),
    onSuccess: () => {
      setSelectedAlbum(undefined)
      queryClient.invalidateQueries({ queryKey: ['albums'] })
    },
  })
  const updateCandidate = useMutation({
    mutationFn: ({ id, accept }: { id: string; accept: boolean }) =>
      accept ? assetApi.acceptCandidate(id) : assetApi.rejectCandidate(id),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['asset-link-candidates'] })
      queryClient.invalidateQueries({ queryKey: ['library', 'photos'] })
    },
  })
  const resolveOrphan = useMutation({
    mutationFn: ({ xmpPath, action }: {
      xmpPath: string
      action: 'keep' | 'restore' | 'retry'
    }) => metadataApi.resolveOrphan(xmpPath, action),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ['metadata-orphans'] }),
  })
  const relinkVolume = useMutation({
    mutationFn: async (oldRoot: string) => {
      const newRoot = await window.gather.selectDirectory(t('dialog.selectPhotoFolder'))
      if (!newRoot) return 0
      return assetApi.relinkRoot(oldRoot, newRoot)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['asset-volumes'] })
      queryClient.invalidateQueries({ queryKey: ['library', 'photos'] })
    },
  })

  return (
    <div className={styles.page}>
      <header className={styles.header}>
        <div>
          <p className={styles.eyebrow}>{t('library.eyebrow')}</p>
          <h1>{t('library.title')}</h1>
          <p className={styles.muted}>{t('library.subtitle')}</p>
        </div>
        <select value={sessionFilter} onChange={event => setSessionFilter(event.target.value)}>
          <option value="">{t('library.allSessions')}</option>
          {sessions.map(session => (
            <option key={session.id} value={session.id}>{t('library.sessionOption', { name: session.name, count: session.photoCount })}</option>
          ))}
        </select>
      </header>

      <div className={styles.filters}>
        <input value={search} onChange={event => setSearch(event.target.value)} placeholder={t('library.searchPlaceholder')} />
        <select value={rating} onChange={event => setRating(event.target.value)}>
          <option value="">{t('library.allRatings')}</option>
          {[1, 2, 3, 4, 5].map(value => <option key={value} value={value}>{t('library.atLeastStars', { count: value })}</option>)}
        </select>
        <select value={label} onChange={event => setLabel(event.target.value)}>
          <option value="">{t('library.allColors')}</option>
          {COLOR_LABELS.filter(Boolean).map(value => <option key={value} value={value}>{value}</option>)}
        </select>
        <select value={status} onChange={event => setStatus(event.target.value)}>
          <option value="">{t('library.allOnlineStatus')}</option>
          <option value="online">{t('library.online')}</option>
          <option value="missing">{t('library.offline')}</option>
        </select>
        <input value={keyword} onChange={event => setKeyword(event.target.value)} placeholder={t('library.keywordPlaceholder')} />
        <input value={person} onChange={event => setPerson(event.target.value)} placeholder={t('library.personPlaceholder')} />
        <input value={directory} onChange={event => setDirectory(event.target.value)} placeholder={t('library.directoryPlaceholder')} />
        <select value={volume} onChange={event => setVolume(event.target.value)}>
          <option value="">{t('library.allVolumes')}</option>
          {volumes.map(item => (
            <option key={item.volumeId} value={item.volumeId}>
              {item.roots[0] || item.volumeId}
            </option>
          ))}
        </select>
        <select value={duplicates} onChange={event => setDuplicates(event.target.value)}>
          <option value="">{t('library.allDuplicates')}</option>
          <option value="yes">{t('library.hasDuplicates')}</option>
          <option value="no">{t('library.noDuplicates')}</option>
        </select>
        <select value={recentDays} onChange={event => setRecentDays(event.target.value)}>
          <option value="">{t('library.allImportTime')}</option>
          <option value="1">{t('library.last24h')}</option>
          <option value="7">{t('library.last7d')}</option>
          <option value="30">{t('library.last30d')}</option>
        </select>
        <button onClick={() => {
          setSearch(''); setRating(''); setLabel(''); setStatus(''); setKeyword('')
          setDirectory(''); setVolume(''); setPerson(''); setDuplicates(''); setRecentDays('')
        }}>{t('library.clearFilters')}</button>
      </div>

      <div className={styles.layout}>
        <aside className={styles.sidebar}>
          <h2>{t('library.smartAlbums')}</h2>
          <button
            className={!selectedAlbum ? styles.selected : ''}
            onClick={() => setSelectedAlbum(undefined)}
          >
            {t('library.allPhotos')}
          </button>
          {albums.map(album => (
            <button
              key={album.id}
              className={selectedAlbum === album.id ? styles.selected : ''}
              disabled={Boolean(album.validationError)}
              title={album.validationError || undefined}
              onClick={() => setSelectedAlbum(album.id)}
            >
              {album.validationError ? '⚠️' : album.icon} {album.name}
            </button>
          ))}
          <input value={albumName} onChange={event => setAlbumName(event.target.value)} placeholder={t('library.newAlbumPlaceholder')} />
          <button
            disabled={!albumName.trim() || createAlbum.isPending}
            onClick={() => createAlbum.mutate()}
          >
            {createAlbum.isPending ? t('library.saving') : t('library.createWithFilters')}
          </button>
          {selectedAlbum && (
            <>
              <button disabled={updateAlbum.isPending} onClick={() => updateAlbum.mutate()}>
                {t('library.updateAlbum')}
              </button>
              <button className={styles.danger} onClick={() => deleteAlbum.mutate(selectedAlbum)}>
                {t('library.deleteAlbum')}
              </button>
            </>
          )}

          <div className={styles.divider} />
          <h2>{t('library.rawJpegLink')}</h2>
          <p className={styles.help}>
            {t('library.rawJpegHelp')}
          </p>
          {linkCandidates.slice(0, 24).map(candidate => (
            <div className={styles.candidate} key={candidate.id}>
              <span title={candidate.leftPath}>{candidate.leftPath.split(/[/\\]/).pop()}</span>
              <span title={candidate.rightPath}>{candidate.rightPath.split(/[/\\]/).pop()}</span>
              <small>
                {candidate.status === 'accepted'
                  ? t('library.linked')
                  : candidate.status === 'rejected' ? t('library.rejected') : t('library.pending', { percent: Math.round(candidate.confidence * 100) })}
              </small>
              <div className={styles.candidateActions}>
                {candidate.status !== 'accepted' && (
                  <button disabled={updateCandidate.isPending} onClick={() => updateCandidate.mutate({ id: candidate.id, accept: true })}>
                    {t('library.link')}
                  </button>
                )}
                {candidate.status !== 'rejected' && (
                  <button disabled={updateCandidate.isPending} onClick={() => updateCandidate.mutate({ id: candidate.id, accept: false })}>
                    {candidate.status === 'accepted' ? t('library.split') : t('library.reject')}
                  </button>
                )}
              </div>
            </div>
          ))}
          {linkCandidates.length === 0 && <p className={styles.muted}>{t('library.noCandidates')}</p>}
          {metadataOrphans.length > 0 && (
            <>
              <div className={styles.divider} />
              <h2>{t('library.orphanXmp')}</h2>
              <p className={styles.help}>{t('library.orphanHelp')}</p>
              {metadataOrphans.slice(0, 24).map(orphan => (
                <div className={styles.candidate} key={orphan.xmpPath}>
                  <span title={orphan.xmpPath}>{orphan.xmpPath.split(/[/\\]/).pop()}</span>
                  <small>{orphan.status}{orphan.errorMessage ? ` · ${translateErrorCode(orphan.errorMessage)}` : ''}</small>
                  <div className={styles.candidateActions}>
                    {['pending', 'failed'].includes(orphan.status) && (
                      <button onClick={() => resolveOrphan.mutate({ xmpPath: orphan.xmpPath, action: 'retry' })}>{t('library.retry')}</button>
                    )}
                    <button onClick={() => resolveOrphan.mutate({ xmpPath: orphan.xmpPath, action: 'keep' })}>{t('library.keepXmp')}</button>
                    <button onClick={() => resolveOrphan.mutate({ xmpPath: orphan.xmpPath, action: 'restore' })}>{t('library.restoreOriginal')}</button>
                  </div>
                </div>
              ))}
              {metadataOrphans.length > 24 && (
                <p className={styles.muted}>{t('library.orphanMore', { count: metadataOrphans.length - 24 })}</p>
              )}
            </>
          )}
          {volumes.some(volume => volume.offlineFiles > 0) && (
            <>
              <div className={styles.divider} />
              <h2>{t('library.offlineVolumes')}</h2>
              {volumes.filter(volume => volume.offlineFiles > 0).map(volume => (
                <div className={styles.candidate} key={volume.volumeId}>
                  <span title={volume.roots.join(', ')}>{volume.roots.join('、') || volume.volumeId}</span>
                  <small>{t('library.offlineFiles', { count: volume.offlineFiles })}</small>
                  {volume.roots.map(root => (
                    <button key={root} onClick={() => relinkVolume.mutate(root)}>{t('library.relink')}</button>
                  ))}
                </div>
              ))}
            </>
          )}
        </aside>

        <main className={styles.content}>
          <div className={styles.toolbar}>
            <span>{isLoading ? t('library.loading') : t('library.totalCount', { count: total })}</span>
            <span>{t('library.range', { start: Math.min(page * PAGE_SIZE + 1, Math.max(1, total)), end: Math.min((page + 1) * PAGE_SIZE, total) })}</span>
          </div>
          <div className={styles.grid}>
            {photos.map(photo => (
              <article key={photo.assetId} className={styles.card}>
                <div className={styles.thumbnail}>
                  <img
                    src={imageApi.thumbnailUrl(photo.filepath, 512)}
                    alt={photo.filename}
                    loading="lazy"
                    onError={(e) => { e.currentTarget.style.display = 'none' }}
                  />
                  {photo.status === 'missing' && <span className={styles.offline}>{t('library.offline')}</span>}
                </div>
                <strong title={photo.filename}>{photo.filename}</strong>
                <span>{photo.rating > 0 ? `${'★'.repeat(photo.rating)}${'☆'.repeat(5 - photo.rating)}` : t('library.unrated')}</span>
                <span>{photo.label || t('library.noLabel')} · {photo.sessionNames.join('、')}</span>
                {photo.keywords.length > 0 && <small>{photo.keywords.slice(0, 4).join(' · ')}</small>}
              </article>
            ))}
            {isError && (
              <p className={styles.muted}>
                {t('error.queryFailed', { message: translateError(error) })}
                <button className={styles.retryBtn} onClick={() => refetch()}>{t('common.retry')}</button>
              </p>
            )}
            {!isLoading && !isError && photos.length === 0 && <p className={styles.muted}>{t('library.noPhotos')}</p>}
          </div>
          <footer className={styles.pagination}>
            <button disabled={page === 0} onClick={() => setPage(value => Math.max(0, value - 1))}>{t('library.prevPage')}</button>
            <span>{page + 1} / {Math.max(1, Math.ceil(total / PAGE_SIZE))}</span>
            <button disabled={(page + 1) * PAGE_SIZE >= total} onClick={() => setPage(value => value + 1)}>{t('library.nextPage')}</button>
          </footer>
        </main>
      </div>
    </div>
  )
}
