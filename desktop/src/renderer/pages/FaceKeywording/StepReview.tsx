import React, { useCallback, useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useFaceKwStore, type ClusterData, type ClusterMemberData } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'
import { imageApi } from '../../api/image'
import { useSettingsStore } from '../../stores/settingsStore'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import styles from './StepReview.module.css'

const MAX_PREVIEW_MEMBERS = 4

export default function StepReview() {
  const {
    sessionId,
    selectedClusterId,
    selectCluster,
  } = useFaceKwStore()
  const queryClient = useQueryClient()
  const [searchParams, setSearchParams] = useSearchParams()
  const settings = useSettingsStore((s) => s.settings)
  const loadSettings = useSettingsStore((s) => s.load)
  const configuredThumbSize = parseInt(settings['thumbnail_size'] ?? '1024', 10)
  const thumbSize = configuredThumbSize <= 320 ? 128 : 256

  useEffect(() => {
    if (Object.keys(settings).length === 0) loadSettings()
  }, [loadSettings])
  const { data: clusters = [] } = useQuery({
    queryKey: ['face-clusters', sessionId],
    queryFn: async () => (await faceKwApi.getClusters(sessionId!)).map(cluster => ({
      ...cluster,
      binding: cluster.binding ?? null,
    })),
    enabled: Boolean(sessionId),
  })
  const refreshClusters = useCallback(async () => {
    await queryClient.invalidateQueries({ queryKey: ['face-clusters', sessionId] })
  }, [queryClient, sessionId])

  const roleFilter = searchParams.get('role')
  const visibleClusters = roleFilter
    ? clusters.filter((c) => c.binding?.roleName === roleFilter)
    : clusters
  const clearRoleFilter = useCallback(() => {
    setSearchParams({}, { replace: true })
  }, [setSearchParams])

  const selectedCluster = clusters.find((c) => c.id === selectedClusterId) ?? null

  const [roleName, setRoleName] = useState(selectedCluster?.binding?.roleName ?? '')
  const [keywords, setKeywords] = useState(selectedCluster?.binding?.keywords?.join(', ') ?? '')
  const [mergeTargetId, setMergeTargetId] = useState<number | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)

  const handleSelectCluster = useCallback(
    (cluster: ClusterData) => {
      if (!sessionId) return
      selectCluster(sessionId, cluster.id)
      setRoleName(cluster.binding?.roleName ?? '')
      setKeywords(cluster.binding?.keywords?.join(', ') ?? '')
    },
    [sessionId, selectCluster],
  )

  const handleBind = useCallback(async () => {
    if (!sessionId || !selectedCluster) return
    const normalizedRoleName = roleName.trim()
    if (!normalizedRoleName) {
      setActionError('角色名称不能为空；它会作为 Capture One 关键词写入。')
      return
    }
    const kwList = keywords.split(',').map((k) => k.trim()).filter(Boolean)
    try {
      setActionError(null)
      await faceKwApi.bind(sessionId, selectedCluster.id, normalizedRoleName, kwList)
      await refreshClusters()
    } catch (e) {
      setActionError(`绑定失败：${e instanceof Error ? e.message : '未知错误'}`)
    }
  }, [sessionId, selectedCluster, roleName, keywords, refreshClusters])

  const handleRemoveMember = useCallback(async (memberId: number) => {
    if (!sessionId || !selectedCluster) return
    try {
      setActionError(null)
      await faceKwApi.removeMember(sessionId, selectedCluster.id, memberId)
      await refreshClusters()
    } catch (e) {
      setActionError(`移除成员失败：${e instanceof Error ? e.message : '未知错误'}`)
    }
  }, [sessionId, selectedCluster, refreshClusters])

  const handleUnbind = useCallback(async () => {
    if (!sessionId || !selectedCluster) return
    if (!window.confirm('解绑后将撤销 Gather 人脸模块写入且未被其他绑定使用的关键词。继续吗？')) return
    try {
      await faceKwApi.unbind(sessionId, selectedCluster.id)
      await refreshClusters()
      setRoleName('')
      setKeywords('')
    } catch (e) {
      setActionError(`解绑失败：${e instanceof Error ? e.message : '未知错误'}`)
    }
  }, [sessionId, selectedCluster, refreshClusters, setRoleName, setKeywords])

  const handleMerge = useCallback(async () => {
    if (!sessionId || !selectedCluster || !mergeTargetId) return
    try {
      await faceKwApi.merge(sessionId, selectedCluster.id, mergeTargetId)
      await refreshClusters()
      selectCluster(sessionId, mergeTargetId)
      setMergeTargetId(null)
    } catch (e) {
      setActionError(`合并失败：${e instanceof Error ? e.message : '未知错误'}`)
    }
  }, [sessionId, selectedCluster, mergeTargetId, refreshClusters, selectCluster])

  return (
    <div className={styles.layout}>
      <section className={styles.clusterPane}>
        <header className={styles.paneHeader}>
          <h3 className={styles.paneTitle}>人脸聚类</h3>
          <span className={styles.paneCount}>{visibleClusters.length} 组</span>
        </header>
        {roleFilter && (
          <div className={styles.roleFilterBar}>
            <span>已按角色「{roleFilter}」筛选</span>
            <button
              type="button"
              className={styles.roleFilterClear}
              onClick={clearRoleFilter}
            >
              清除筛选
            </button>
          </div>
        )}
        <div className={styles.clusterGrid}>
          {visibleClusters.map((cluster) => (
            <button
              type="button"
              key={cluster.id}
              onClick={() => handleSelectCluster(cluster)}
              className={selectedClusterId === cluster.id ? styles.clusterCardSelected : styles.clusterCard}
            >
              <ClusterThumb members={cluster.members} size={cluster.size} thumbSize={thumbSize} />
              <div className={styles.clusterLabel}>{cluster.label}</div>
              <div className={styles.clusterMeta}>{cluster.size} 张人脸</div>
              {cluster.binding && (
                <div className={styles.bindingBadge}>{cluster.binding.roleName}</div>
              )}
            </button>
          ))}
        </div>
      </section>

      <aside className={styles.detailPane}>
        {selectedCluster ? (
          <>
            <header className={styles.detailHeader}>
              <h3 className={styles.detailTitle}>{selectedCluster.label}</h3>
              <span className={styles.detailMeta}>{selectedCluster.size} 个成员</span>
            </header>

            <div className={styles.memberList}>
              {selectedCluster.members.map((m, idx) => (
                <div
                  key={`${m.photoId}-${idx}`}
                  className={styles.member}
                >
                  <span className={styles.memberIndex}>#{idx + 1}</span>
                  <span className={styles.memberName}>{m.filename}</span>
                  <span className={styles.confidence}>{(m.confidence * 100).toFixed(0)}%</span>
                  <button
                    type="button"
                    onClick={() => void handleRemoveMember(m.memberId)}
                    title="从该人脸聚类中移除"
                    className={styles.removeButton}
                  >
                    移除
                  </button>
                </div>
              ))}
            </div>

            {actionError && (
              <p className={styles.error}>{actionError}</p>
            )}

            <div className={styles.editor}>
              <label className={styles.fieldLabel} htmlFor="face-role-name">角色名称</label>
              <input
                id="face-role-name"
                value={roleName}
                onChange={(e) => setRoleName(e.target.value)}
                placeholder="例如: 张三"
                className={styles.input}
              />
              <label className={styles.fieldLabel} htmlFor="face-keywords">关键词（逗号分隔）</label>
              <input
                id="face-keywords"
                value={keywords}
                onChange={(e) => setKeywords(e.target.value)}
                placeholder="例如: 人像, 户外, 微笑"
                className={styles.input}
              />
            </div>

            <div className={styles.buttonRow}>
              <button
                type="button"
                onClick={() => void handleBind()}
                className={styles.primaryButton}
              >
                {selectedCluster.binding ? '更新绑定' : '绑定'}
              </button>
              {selectedCluster.binding && (
                <button
                  type="button"
                  onClick={() => void handleUnbind()}
                  className={styles.dangerButton}
                >
                  解绑
                </button>
              )}
            </div>

            <div className={styles.mergePanel}>
              <label className={styles.fieldLabel} htmlFor="face-merge-target">合并到聚类</label>
              <div className={styles.mergeRow}>
                <select
                  id="face-merge-target"
                  value={mergeTargetId ?? ''}
                  onChange={(e) => setMergeTargetId(e.target.value ? Number(e.target.value) : null)}
                  className={styles.select}
                >
                  <option value="">选择目标...</option>
                  {clusters
                    .filter((c) => c.id !== selectedCluster.id)
                    .map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.label} ({c.size} 张人脸)
                      </option>
                    ))}
                </select>
                <button
                  type="button"
                  onClick={() => void handleMerge()}
                  disabled={!mergeTargetId}
                  className={styles.secondaryButton}
                >
                  合并
                </button>
              </div>
            </div>
          </>
        ) : (
          <div className={styles.emptyDetail}>选择一个聚类以查看详情</div>
        )}
      </aside>
    </div>
  )
}

function ClusterThumb({ members, size, thumbSize }: {
  members: ClusterMemberData[]
  size: number
  thumbSize: number
}) {
  const [failed, setFailed] = useState<Set<string>>(() => new Set())

  const previewMembers = members.slice(0, MAX_PREVIEW_MEMBERS)

  if (previewMembers.length === 0) {
    return (
      <div className={styles.clusterThumb}>
        <span>{size}</span>
      </div>
    )
  }

  return (
    <div className={styles.clusterThumb}>
      <div className={styles.faceGrid}>
        {previewMembers.map((m) => {
          const key = `${m.memberId}-${m.photoPath}`
          const src = !failed.has(key) ? imageApi.thumbnailUrl(m.photoPath, thumbSize) : null
          return (
            <div key={key} className={styles.faceCell}>
              {src ? (
                <img
                  src={src}
                  alt={m.filename}
                  loading="lazy"
                  onError={() => setFailed((prev) => new Set(prev).add(key))}
                />
              ) : (
                <div className={styles.facePlaceholder} />
              )}
            </div>
          )
        })}
      </div>
    </div>
  )
}
