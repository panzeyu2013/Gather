import React, { useState, useEffect, useCallback } from 'react'
import { useParams } from 'react-router-dom'
import { duplicateApi } from '../../api/duplicate'
import { imageApi } from '../../api/image'
import type { DuplicateScanResult, DuplicateGroup, DuplicateGroupMember } from '@gather/shared'
import { useTranslation } from '../../locales'
import { translateError } from '../../utils/errors'
import styles from './Duplicates.module.css'

function ThumbnailImage({ path, className }: { path: string; className?: string }) {
  const filename = path.split(/[/\\]/).pop() ?? path
  return <img src={imageApi.thumbnailUrl(path, 256)} alt={filename} className={className} />
}

function MemberCard({
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
}

function GroupCard({
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

  const recommendation = [...group.members].sort((a, b) => {
    const scoreA = ((a.fileSize ?? 0) * 1000) + (new Date(a.fileMtime ?? 0).getTime() || 0)
    const scoreB = ((b.fileSize ?? 0) * 1000) + (new Date(b.fileMtime ?? 0).getTime() || 0)
    return scoreB - scoreA
  })[0]

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
        {group.members.map((member) => (
          <div key={member.id} className={styles.memberWrapper}>
            <MemberCard member={member} onToggle={onToggleMember} />
            {recommendation && member.id === recommendation.id && (
              <span className={styles.recommendBadge}>{t('duplicate.recommend')}</span>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}

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

  const handleResolveGroup = async (groupId: number, resolution: 'keep_one' | 'keep_all') => {
    try {
      await duplicateApi.resolveGroup(groupId, resolution)
      await loadGroups()
    } catch (e) {
      setError(e instanceof Error ? translateError(e) : t('error.resolveGroupFailed'))
    }
  }

  const handleToggleMember = async (memberId: number, isKept: boolean) => {
    try {
      await duplicateApi.resolveMember(memberId, isKept)
      await loadGroups()
    } catch (e) {
      setError(e instanceof Error ? translateError(e) : t('error.updateMemberFailed'))
    }
  }

  const filteredGroups = groups.filter(
    (g) => g.groupType === activeTab,
  )

  const exactGroups = groups.filter((g) => g.groupType === 'exact')
  const visualGroups = groups.filter((g) => g.groupType === 'visual')

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
        {filteredGroups.map((group) => (
          <GroupCard
            key={group.id}
            group={group}
            onResolveGroup={handleResolveGroup}
            onToggleMember={handleToggleMember}
          />
        ))}
      </div>
    </div>
  )
}
