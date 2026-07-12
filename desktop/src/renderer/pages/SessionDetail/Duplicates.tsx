import React, { useState, useEffect, useCallback } from 'react'
import { useParams } from 'react-router-dom'
import { duplicateApi } from '../../api/duplicate'
import type { DuplicateScanResult, DuplicateGroup, DuplicateGroupMember } from '@gather/shared'
import styles from './Duplicates.module.css'

function ThumbnailImage({ path, className }: { path: string; className?: string }) {
  const [src, setSrc] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    duplicateApi.getThumbnail(path).then((base64) => {
      if (!cancelled) {
        setSrc(`data:image/jpeg;base64,${base64}`)
      }
    }).catch(() => {
      if (!cancelled) setSrc(null)
    })
    return () => { cancelled = true }
  }, [path])

  const filename = path.split(/[/\\]/).pop() ?? path

  if (!src) {
    return (
      <div className={className ?? styles.thumbPlaceholder}>
        <span>{filename}</span>
      </div>
    )
  }

  return <img src={src} alt={filename} className={className} />
}

function MemberCard({
  member,
  onToggle,
}: {
  member: DuplicateGroupMember
  onToggle: (memberId: number, isKept: boolean) => void
}) {
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
        {member.isKept ? '保留' : '丢弃'}
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
          {group.groupType === 'exact' ? '完全重复' : '视觉相似'} · {group.memberCount} 张照片
          {group.resolution ? ` · ${group.resolution === 'keep_one' ? '保留最佳' : '保留全部'}` : ''}
        </h3>
        <div className={styles.groupActions}>
          <button
            className={styles.resolveBtn}
            onClick={() => setShowResolve(!showResolve)}
          >
            处理
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
            保留最佳
          </button>
          <button
            className={styles.resolveOption}
            onClick={() => {
              onResolveGroup(group.id, 'keep_all')
              setShowResolve(false)
            }}
          >
            保留全部
          </button>
        </div>
      )}

      <div className={styles.memberGrid}>
        {group.members.map((member) => (
          <div key={member.id} className={styles.memberWrapper}>
            <MemberCard member={member} onToggle={onToggleMember} />
            {recommendation && member.id === recommendation.id && (
              <span className={styles.recommendBadge}>推荐</span>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}

export default function Duplicates() {
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
      setError(e instanceof Error ? e.message : 'Failed to load groups')
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
      const result = await duplicateApi.scan(sessionId, undefined, visualThreshold)
      setScanResult(result)
      await loadGroups()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Scan failed')
    } finally {
      setScanning(false)
    }
  }

  const handleResolveGroup = async (groupId: number, resolution: 'keep_one' | 'keep_all') => {
    try {
      await duplicateApi.resolveGroup(groupId, resolution)
      await loadGroups()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Resolve failed')
    }
  }

  const handleToggleMember = async (memberId: number, isKept: boolean) => {
    try {
      await duplicateApi.resolveMember(memberId, isKept)
      await loadGroups()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Toggle failed')
    }
  }

  const filteredGroups = groups.filter(
    (g) => g.groupType === activeTab,
  )

  const exactGroups = groups.filter((g) => g.groupType === 'exact')
  const visualGroups = groups.filter((g) => g.groupType === 'visual')

  if (!sessionId) {
    return <div className={styles.page}><p>未选择工作区</p></div>
  }

  return (
    <div className={styles.page}>
      <h2 className={styles.title}>重复照片检测</h2>

      <div className={styles.panel}>
        <div className={styles.controlRow}>
          <label className={styles.controlLabel}>
            视觉相似阈值: <strong>{visualThreshold}</strong>
          </label>
          <input
            type="range"
            min={0}
            max={10}
            value={visualThreshold}
            onChange={(e) => setVisualThreshold(Number(e.target.value))}
            className={styles.slider}
          />
          <span className={styles.rangeHint}>0 (严格) — 10 (宽松)</span>
        </div>

        <button
          className={styles.scanBtn}
          onClick={handleScan}
          disabled={scanning}
        >
          {scanning ? '扫描中...' : '开始扫描'}
        </button>

        {scanResult && (
          <div className={styles.scanStats}>
            <span>完全重复: {scanResult.exactGroups.length} 组</span>
            <span>视觉相似: {scanResult.visualGroups.length} 组</span>
            <span>总计重复: {scanResult.totalDuplicates} 张</span>
          </div>
        )}

        {error && <p className={styles.error}>{error}</p>}
      </div>

      <div className={styles.tabs}>
        <button
          className={activeTab === 'exact' ? styles.tabActive : styles.tab}
          onClick={() => setActiveTab('exact')}
        >
          完全重复 ({exactGroups.length})
        </button>
        <button
          className={activeTab === 'visual' ? styles.tabActive : styles.tab}
          onClick={() => setActiveTab('visual')}
        >
          视觉相似 ({visualGroups.length})
        </button>
      </div>

      {loading && <p className={styles.loading}>加载中...</p>}

      {!loading && filteredGroups.length === 0 && scanResult && (
        <div className={styles.empty}>
          <p>未发现{activeTab === 'exact' ? '完全重复' : '视觉相似'}的照片</p>
        </div>
      )}

      {!loading && filteredGroups.length === 0 && !scanResult && (
        <div className={styles.empty}>
          <p>点击"开始扫描"按钮检测重复照片</p>
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
