import React, { useState, useEffect, useCallback, useMemo, memo } from 'react'
import { useParams } from 'react-router-dom'
import { duplicateApi } from '../../api/duplicate'
import { imageApi } from '../../api/image'
import type { DuplicateScanResult, DuplicateGroup, DuplicateGroupMember } from '@gather/shared'
import { useTranslation } from '../../locales'
import { translateError } from '../../utils/errors'
import styles from './Duplicates.module.css'

const DEFAULT_MEMBER_LIMIT = 12
const GROUP_PAGE_SIZE = 100

function ThumbnailImage({ path, className }: { path: string; className?: string }) {
  const [failed, setFailed] = useState(false)
  const filename = path.split(/[/\\]/).pop() ?? path
  if (failed) {
    return <div className={className ? `${className} ${styles.thumbPlaceholder}` : styles.thumbPlaceholder} />
  }
  return (
    <img
      src={imageApi.thumbnailUrl(path, 256)}
      alt={filename}
      loading="lazy"
      className={className}
      onError={() => setFailed(true)}
    />
  )
}

const MemberCard = memo(function MemberCard({
  member,
  onToggle,
}: {
  member: DuplicateGroupMember
  onToggle: (memberId: number, isKept: boolean) => void
}) {
  const { t } = useTranslation()
  return (
    <div className={`${styles.memberCard} ${member.isKept ? styles.memberKept : styles.memberRejected}`}>
      <ThumbnailImage path={member.filepath} className={styles.memberThumb} />
      <span className={styles.memberName}>{member.filename}</span>
      <span className={styles.memberMeta}>
        {member.fileSize != null ? `${(member.fileSize / 1024 / 1024).toFixed(1)} MB` : ''}
      </span>
      <button
        className={member.isKept ? styles.keptBtn : styles.rejectBtn}
        onClick={() => onToggle(member.id, !member.isKept)}
      >
        {member.isKept ? t('duplicate.keep') : t('duplicate.discard')}
      </button>
    </div>
  )
})

const GroupCard = memo(function GroupCard({
  group,
  onResolveGroup,
  onToggleMember,
}: {
  group: DuplicateGroup
  onResolveGroup: (groupId: number, resolution: 'keep_one' | 'keep_all') => void
  onToggleMember: (memberId: number, isKept: boolean) => void
}) {
  const { t } = useTranslation()
  const [showResolve, setShowResolve] = useState(false)
  const [showAllMembers, setShowAllMembers] = useState(false)

  const recommendation = useMemo(() => {
    const sorted = [...group.members].sort((a, b) => {
      const scoreA = ((a.fileSize ?? 0) * 1000) + (new Date(a.fileMtime ?? 0).getTime() || 0)
      const scoreB = ((b.fileSize ?? 0) * 1000) + (new Date(b.fileMtime ?? 0).getTime() || 0)
      return scoreB - scoreA
    })
    return sorted[0]
  }, [group.members])

  const visibleMembers = showAllMembers
    ? group.members
    : group.members.slice(0, DEFAULT_MEMBER_LIMIT)

  return (
    <div className={styles.groupCard}>
      <div className={styles.groupHeader}>
        <h3 className={styles.groupTitle}>
          {t('duplicate.groupTitle', {
            type: group.groupType === 'exact' ? t('duplicate.exactType') : t('duplicate.visualType'),
            count: group.memberCount,
          })}
          {group.resolution ? ` · ${group.resolution === 'keep_one' ? t('duplicate.keepBest') : t('duplicate.keepAll')}` : ''}
        </h3>
        <div className={styles.groupActions}>
          <button
            className={styles.resolveBtn}
            onClick={() => setShowResolve(!showResolve)}
          >
            {t('duplicate.resolve')}
          </button>
        </div>
      </div>

      {showResolve && (
        <div className={styles.resolvePanel}>
          <button
            className={styles.resolveOption}
            onClick={() => {
              onResolveGroup(group.id, 'keep_one')
              setShowResolve(false)
            }}
          >
            {t('duplicate.keepBest')}
          </button>
          <button
            className={styles.resolveOption}
            onClick={() => {
              onResolveGroup(group.id, 'keep_all')
              setShowResolve(false)
            }}
          >
            {t('duplicate.keepAll')}
          </button>
        </div>
      )}

      <div className={styles.memberGrid}>
        {visibleMembers.map((member) => (
          <div key={member.id} className={styles.memberWrapper}>
            <MemberCard member={member} onToggle={onToggleMember} />
            {recommendation && member.id === recommendation.id && (
              <span className={styles.recommendBadge}>{t('duplicate.recommend')}</span>
            )}
          </div>
        ))}
      </div>

      {group.members.length > DEFAULT_MEMBER_LIMIT && (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '0 0 12px' }}>
          <button
            type="button"
            className={styles.resolveBtn}
            onClick={() => setShowAllMembers((value) => !value)}
          >
            {showAllMembers ? '收起' : `展开全部 (共 ${group.members.length} 张)`}
          </button>
        </div>
      )}
    </div>
  )
})

export default function Duplicates() {
  const { t } = useTranslation()
  const { sessionId } = useParams<{ sessionId: string }>()
  const [scanResult, setScanResult] = useState<DuplicateScanResult | null>(null)
  const [groups, setGroups] = useState<DuplicateGroup[]>([])
  const [activeTab, setActiveTab] = useState<'exact' | 'visual'>('exact')
  const [loading, setLoading] = useState(false)
  const [scanning, setScanning] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [visualThreshold, setVisualThreshold] = useState(4)

  const loadGroups = useCallback(async () => {
    if (!sessionId) return
    setLoading(true)
    setError(null)
    try {
      const data = await duplicateApi.getGroups(sessionId)
      setGroups(data)
    } catch (e) {
      setError(e instanceof Error ? translateError(e) : t('error.loadDuplicatesFailed'))
    } finally {
      setLoading(false)
    }
  }, [sessionId])

  useEffect(() => {
    loadGroups()
  }, [loadGroups])

  const handleScan = async () => {
    if (!sessionId) return
    setScanning(true)
    setError(null)
    try {
      const result = await duplicateApi.scan(sessionId, visualThreshold)
      setScanResult(result)
      await loadGroups()
    } catch (e) {
      setError(e instanceof Error ? translateError(e) : t('error.scanDuplicatesFailed'))
    } finally {
      setScanning(false)
    }
  }

  // Local updates instead of a full reload: the API confirms the change
  // server-side, so patching just the affected member/group keeps the UI in
  // sync without re-fetching every group. The member patch mirrors
  // DuplicateService.resolveGroup (desktop/src/main/services/duplicate/):
  // keep_one keeps only the best member (score = fileSize*1000 + mtime ms,
  // first member wins ties) and marks the rest discarded; keep_all keeps
  // every member, and every member inherits the group resolution.
  const handleResolveGroup = useCallback(async (groupId: number, resolution: 'keep_one' | 'keep_all') => {
    try {
      const ok = await duplicateApi.resolveGroup(groupId, resolution)
      if (!ok) {
        setError('处理照片组失败，请重试')
        return
      }
      setGroups((prev) => prev.map((g) => {
        if (g.id !== groupId) return g
        if (resolution === 'keep_all') {
          return {
            ...g,
            resolution,
            members: g.members.map((m) => ({ ...m, isKept: true, resolution })),
          }
        }
        let bestId: number | undefined = g.members[0]?.id
        let bestScore = -1
        for (const m of g.members) {
          const score = ((m.fileSize ?? 0) * 1000) + new Date(m.fileMtime || 0).getTime()
          if (score > bestScore) {
            bestScore = score
            bestId = m.id
          }
        }
        return {
          ...g,
          resolution,
          members: g.members.map((m) => ({
            ...m,
            isKept: m.id === bestId,
            resolution,
          })),
        }
      }))
    } catch (e) {
      setError(e instanceof Error ? translateError(e) : t('error.resolveGroupFailed'))
    }
  }, [])

  const handleToggleMember = useCallback(async (memberId: number, isKept: boolean) => {
    try {
      const ok = await duplicateApi.resolveMember(memberId, isKept)
      if (!ok) {
        setError('更新照片状态失败，请重试')
        return
      }
      setGroups((prev) => prev.map((g) =>
        g.members.some((m) => m.id === memberId)
          ? {
              ...g,
              members: g.members.map((m) => (
                m.id === memberId
                  ? { ...m, isKept, resolution: isKept ? 'keep_all' : 'keep_one' }
                  : m
              )),
            }
          : g,
      ))
    } catch (e) {
      setError(e instanceof Error ? translateError(e) : t('error.updateMemberFailed'))
    }
  }, [])

  // Single pass over `groups` deriving every filtered list, so tab rendering
  // and the tab badges don't each run their own full filter per render.
  const { filteredGroups, exactGroups, visualGroups } = useMemo(() => {
    const exact: DuplicateGroup[] = []
    const visual: DuplicateGroup[] = []
    for (const g of groups) {
      if (g.groupType === 'exact') exact.push(g)
      else visual.push(g)
    }
    return {
      filteredGroups: activeTab === 'exact' ? exact : visual,
      exactGroups: exact,
      visualGroups: visual,
    }
  }, [groups, activeTab])

  // Hundreds of groups is typical; cap the mounted group list and let the user
  // load more in chunks instead of mounting every group (and every member) at
  // once. Reset the cap when the tab switches to a different group set.
  const [visibleGroupCount, setVisibleGroupCount] = useState(GROUP_PAGE_SIZE)
  useEffect(() => {
    setVisibleGroupCount(GROUP_PAGE_SIZE)
  }, [activeTab])

  const visibleGroups = filteredGroups.slice(0, visibleGroupCount)

  if (!sessionId) {
    return <div className={styles.page}><p>{t('duplicate.noWorkspace')}</p></div>
  }

  return (
    <div className={styles.page}>
      <h2 className={styles.title}>{t('duplicate.title')}</h2>

      <div className={styles.panel}>
        <div className={styles.controlRow}>
          <label className={styles.controlLabel}>
            {t('duplicate.visualThreshold')}: <strong>{visualThreshold}</strong>
          </label>
          <input
            type="range"
            min={0}
            max={10}
            value={visualThreshold}
            onChange={(e) => setVisualThreshold(Number(e.target.value))}
            className={styles.slider}
          />
          <span className={styles.rangeHint}>{t('duplicate.rangeHint')}</span>
        </div>

        <button
          className={styles.scanBtn}
          onClick={handleScan}
          disabled={scanning}
        >
          {scanning ? t('duplicate.scanning') : t('duplicate.startScan')}
        </button>

        {scanResult && (
          <div className={styles.scanStats}>
            <span>{t('duplicate.exactGroups', { count: scanResult.exactGroups.length })}</span>
            <span>{t('duplicate.visualGroups', { count: scanResult.visualGroups.length })}</span>
            <span>{t('duplicate.totalDuplicates', { count: scanResult.totalDuplicates })}</span>
          </div>
        )}

        {error && <p className={styles.error}>{error}</p>}
      </div>

      <div className={styles.tabs}>
        <button
          className={activeTab === 'exact' ? styles.tabActive : styles.tab}
          onClick={() => setActiveTab('exact')}
        >
          {t('duplicate.exactTab', { count: exactGroups.length })}
        </button>
        <button
          className={activeTab === 'visual' ? styles.tabActive : styles.tab}
          onClick={() => setActiveTab('visual')}
        >
          {t('duplicate.visualTab', { count: visualGroups.length })}
        </button>
      </div>

      {loading && <p className={styles.loading}>{t('duplicate.loading')}</p>}

      {!loading && filteredGroups.length === 0 && scanResult && (
        <div className={styles.empty}>
          <p>{activeTab === 'exact' ? t('duplicate.noExactFound') : t('duplicate.noVisualFound')}</p>
        </div>
      )}

      {!loading && filteredGroups.length === 0 && !scanResult && (
        <div className={styles.empty}>
          <p>{t('duplicate.scanHint')}</p>
        </div>
      )}

      <div className={styles.grid}>
        {visibleGroups.map((group) => (
          <GroupCard
            key={group.id}
            group={group}
            onResolveGroup={handleResolveGroup}
            onToggleMember={handleToggleMember}
          />
        ))}
      </div>

      {filteredGroups.length > visibleGroupCount && (
        <div style={{ display: 'flex', justifyContent: 'center', padding: '12px 0' }}>
          <button
            type="button"
            className={styles.resolveBtn}
            onClick={() => setVisibleGroupCount((count) => count + GROUP_PAGE_SIZE)}
          >
            {t('duplicate.loadMore', { count: filteredGroups.length - visibleGroupCount })}
          </button>
        </div>
      )}
    </div>
  )
}
