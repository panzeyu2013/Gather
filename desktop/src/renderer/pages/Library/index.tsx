import React, { useEffect, useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { filterApi, albumApi } from '../../api/filter'
import { assetApi } from '../../api/assets'
import { sessionApi } from '../../api/session'
import { imageApi } from '../../api/image'
import { metadataApi } from '../../api/metadata'
import type { FilterGroup, FilterRule } from '@gather/shared'
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
      const newRoot = await window.gather.selectDirectory()
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
          <p className={styles.eyebrow}>GLOBAL LIBRARY</p>
          <h1>全局图库</h1>
          <p className={styles.muted}>以同一逻辑照片为单位，跨 Session 浏览、筛选和管理。</p>
        </div>
        <select value={sessionFilter} onChange={event => setSessionFilter(event.target.value)}>
          <option value="">全部 Session</option>
          {sessions.map(session => (
            <option key={session.id} value={session.id}>{session.name}（{session.photoCount}）</option>
          ))}
        </select>
      </header>

      <div className={styles.filters}>
        <input value={search} onChange={event => setSearch(event.target.value)} placeholder="搜索文件名" />
        <select value={rating} onChange={event => setRating(event.target.value)}>
          <option value="">全部星级</option>
          {[1, 2, 3, 4, 5].map(value => <option key={value} value={value}>至少 {value} 星</option>)}
        </select>
        <select value={label} onChange={event => setLabel(event.target.value)}>
          <option value="">全部颜色</option>
          {COLOR_LABELS.filter(Boolean).map(value => <option key={value} value={value}>{value}</option>)}
        </select>
        <select value={status} onChange={event => setStatus(event.target.value)}>
          <option value="">全部在线状态</option>
          <option value="online">在线</option>
          <option value="missing">离线</option>
        </select>
        <input value={keyword} onChange={event => setKeyword(event.target.value)} placeholder="关键词" />
        <input value={person} onChange={event => setPerson(event.target.value)} placeholder="人物" />
        <input value={directory} onChange={event => setDirectory(event.target.value)} placeholder="目录路径前缀" />
        <select value={volume} onChange={event => setVolume(event.target.value)}>
          <option value="">全部存储卷</option>
          {volumes.map(item => (
            <option key={item.volumeId} value={item.volumeId}>
              {item.roots[0] || item.volumeId}
            </option>
          ))}
        </select>
        <select value={duplicates} onChange={event => setDuplicates(event.target.value)}>
          <option value="">全部重复状态</option>
          <option value="yes">有重复候选</option>
          <option value="no">无重复候选</option>
        </select>
        <select value={recentDays} onChange={event => setRecentDays(event.target.value)}>
          <option value="">全部导入时间</option>
          <option value="1">最近 24 小时</option>
          <option value="7">最近 7 天</option>
          <option value="30">最近 30 天</option>
        </select>
        <button onClick={() => {
          setSearch(''); setRating(''); setLabel(''); setStatus(''); setKeyword('')
          setDirectory(''); setVolume(''); setPerson(''); setDuplicates(''); setRecentDays('')
        }}>清除筛选</button>
      </div>

      <div className={styles.layout}>
        <aside className={styles.sidebar}>
          <h2>智能相册</h2>
          <button
            className={!selectedAlbum ? styles.selected : ''}
            onClick={() => setSelectedAlbum(undefined)}
          >
            全部照片
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
          <input value={albumName} onChange={event => setAlbumName(event.target.value)} placeholder="新相册名称" />
          <button
            disabled={!albumName.trim() || createAlbum.isPending}
            onClick={() => createAlbum.mutate()}
          >
            {createAlbum.isPending ? '保存中…' : '用当前筛选创建'}
          </button>
          {selectedAlbum && (
            <>
              <button disabled={updateAlbum.isPending} onClick={() => updateAlbum.mutate()}>
                更新为当前筛选
              </button>
              <button className={styles.danger} onClick={() => deleteAlbum.mutate(selectedAlbum)}>
                删除当前相册
              </button>
            </>
          )}

          <div className={styles.divider} />
          <h2>RAW / JPEG 关联</h2>
          <p className={styles.help}>
            拍摄时间和相机信息均匹配的唯一 RAW/JPEG 组合会自动关联；证据不足时等待人工确认。
          </p>
          {linkCandidates.slice(0, 24).map(candidate => (
            <div className={styles.candidate} key={candidate.id}>
              <span title={candidate.leftPath}>{candidate.leftPath.split(/[/\\]/).pop()}</span>
              <span title={candidate.rightPath}>{candidate.rightPath.split(/[/\\]/).pop()}</span>
              <small>
                {candidate.status === 'accepted'
                  ? '已关联'
                  : candidate.status === 'rejected' ? '已拒绝' : `待确认 · ${Math.round(candidate.confidence * 100)}%`}
              </small>
              <div className={styles.candidateActions}>
                {candidate.status !== 'accepted' && (
                  <button disabled={updateCandidate.isPending} onClick={() => updateCandidate.mutate({ id: candidate.id, accept: true })}>
                    关联
                  </button>
                )}
                {candidate.status !== 'rejected' && (
                  <button disabled={updateCandidate.isPending} onClick={() => updateCandidate.mutate({ id: candidate.id, accept: false })}>
                    {candidate.status === 'accepted' ? '拆分' : '拒绝'}
                  </button>
                )}
              </div>
            </div>
          ))}
          {linkCandidates.length === 0 && <p className={styles.muted}>暂无关联候选</p>}
          {metadataOrphans.length > 0 && (
            <>
              <div className={styles.divider} />
              <h2>待恢复 XMP</h2>
              <p className={styles.help}>原 Session 已删除，XMP 操作仍被安全保留。</p>
              {metadataOrphans.slice(0, 24).map(orphan => (
                <div className={styles.candidate} key={orphan.xmpPath}>
                  <span title={orphan.xmpPath}>{orphan.xmpPath.split(/[/\\]/).pop()}</span>
                  <small>{orphan.status}{orphan.errorMessage ? ` · ${orphan.errorMessage}` : ''}</small>
                  <div className={styles.candidateActions}>
                    {['pending', 'failed'].includes(orphan.status) && (
                      <button onClick={() => resolveOrphan.mutate({ xmpPath: orphan.xmpPath, action: 'retry' })}>重试</button>
                    )}
                    <button onClick={() => resolveOrphan.mutate({ xmpPath: orphan.xmpPath, action: 'keep' })}>保留 XMP</button>
                    <button onClick={() => resolveOrphan.mutate({ xmpPath: orphan.xmpPath, action: 'restore' })}>恢复原始</button>
                  </div>
                </div>
              ))}
              {metadataOrphans.length > 24 && (
                <p className={styles.muted}>另有 {metadataOrphans.length - 24} 个待恢复 XMP 未列出</p>
              )}
            </>
          )}
          {volumes.some(volume => volume.offlineFiles > 0) && (
            <>
              <div className={styles.divider} />
              <h2>离线存储卷</h2>
              {volumes.filter(volume => volume.offlineFiles > 0).map(volume => (
                <div className={styles.candidate} key={volume.volumeId}>
                  <span title={volume.roots.join(', ')}>{volume.roots.join('、') || volume.volumeId}</span>
                  <small>{volume.offlineFiles} 个离线文件</small>
                  {volume.roots.map(root => (
                    <button key={root} onClick={() => relinkVolume.mutate(root)}>重新定位…</button>
                  ))}
                </div>
              ))}
            </>
          )}
        </aside>

        <main className={styles.content}>
          <div className={styles.toolbar}>
            <span>{isLoading ? '加载中…' : `共 ${total} 张逻辑照片`}</span>
            <span>第 {Math.min(page * PAGE_SIZE + 1, Math.max(1, total))}–{Math.min((page + 1) * PAGE_SIZE, total)} 张</span>
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
                  {photo.status === 'missing' && <span className={styles.offline}>离线</span>}
                </div>
                <strong title={photo.filename}>{photo.filename}</strong>
                <span>{photo.rating > 0 ? `${'★'.repeat(photo.rating)}${'☆'.repeat(5 - photo.rating)}` : '未评级'}</span>
                <span>{photo.label || '无色标'} · {photo.sessionNames.join('、')}</span>
                {photo.keywords.length > 0 && <small>{photo.keywords.slice(0, 4).join(' · ')}</small>}
              </article>
            ))}
            {isError && (
              <p className={styles.muted}>
                查询失败：{error instanceof Error ? error.message : '未知错误'}
                <button className={styles.retryBtn} onClick={() => refetch()}>重试</button>
              </p>
            )}
            {!isLoading && !isError && photos.length === 0 && <p className={styles.muted}>没有符合条件的照片</p>}
          </div>
          <footer className={styles.pagination}>
            <button disabled={page === 0} onClick={() => setPage(value => Math.max(0, value - 1))}>上一页</button>
            <span>{page + 1} / {Math.max(1, Math.ceil(total / PAGE_SIZE))}</span>
            <button disabled={(page + 1) * PAGE_SIZE >= total} onClick={() => setPage(value => value + 1)}>下一页</button>
          </footer>
        </main>
      </div>
    </div>
  )
}
