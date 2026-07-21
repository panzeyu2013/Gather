import React, { useCallback, useRef, useState } from 'react'
import { useFaceKwStore, type ClusterData } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'

export default function StepReview() {
  const {
    sessionId,
    clusters,
    selectedClusterId,
    selectCluster,
    updateClusterBinding,
    removeCluster,
    mergeClusters: mergeClustersStore,
    setStep,
  } = useFaceKwStore()

  const selectedCluster = clusters.find((c) => c.id === selectedClusterId) ?? null

  const [roleName, setRoleName] = useState(selectedCluster?.binding?.roleName ?? '')
  const [keywords, setKeywords] = useState(selectedCluster?.binding?.keywords?.join(', ') ?? '')
  const [mergeTargetId, setMergeTargetId] = useState<number | null>(null)
  const [thumbnails, setThumbnails] = useState<Record<number, string>>({})
  const loadedRef = useRef<Set<number>>(new Set())

  const loadThumbnail = useCallback(async (clusterId: number) => {
    if (loadedRef.current.has(clusterId)) return
    loadedRef.current.add(clusterId)
    try {
      const { base64 } = await faceKwApi.getClusterThumbnail(clusterId)
      setThumbnails(prev => ({ ...prev, [clusterId]: base64 }))
    } catch (e) {
      console.warn('Failed to load thumbnail', clusterId, e)
      setThumbnails(prev => ({ ...prev, [clusterId]: '' }))
    }
  }, [])

  const handleSelectCluster = useCallback(
    (cluster: ClusterData) => {
      selectCluster(cluster.id)
      setRoleName(cluster.binding?.roleName ?? '')
      setKeywords(cluster.binding?.keywords?.join(', ') ?? '')
    },
    [selectCluster],
  )

  const handleBind = useCallback(async () => {
    if (!sessionId || !selectedCluster) return
    const kwList = keywords.split(',').map((k) => k.trim()).filter(Boolean)
    try {
      await faceKwApi.bind(sessionId, selectedCluster.id, roleName.trim() || 'Unnamed', kwList)
      updateClusterBinding(selectedCluster.id, { roleName: roleName.trim() || 'Unnamed', keywords: kwList })
    } catch (e) {
      console.error('Bind failed:', e)
    }
  }, [sessionId, selectedCluster, roleName, keywords, updateClusterBinding])

  const handleUnbind = useCallback(async () => {
    if (!sessionId || !selectedCluster) return
    try {
      await faceKwApi.unbind(sessionId, selectedCluster.id)
      updateClusterBinding(selectedCluster.id, null)
      setRoleName('')
      setKeywords('')
    } catch (e) {
      console.error('Unbind failed:', e)
    }
  }, [sessionId, selectedCluster, updateClusterBinding])

  const handleMerge = useCallback(async () => {
    if (!sessionId || !selectedCluster || !mergeTargetId) return
    try {
      await faceKwApi.merge(sessionId, selectedCluster.id, mergeTargetId)
      mergeClustersStore(selectedCluster.id, mergeTargetId)
      selectCluster(mergeTargetId)
      setMergeTargetId(null)
      loadedRef.current.delete(mergeTargetId)
      setThumbnails(prev => {
        const next = { ...prev }
        delete next[mergeTargetId]
        return next
      })
    } catch (e) {
      console.error('Merge failed:', e)
    }
  }, [sessionId, selectedCluster, mergeTargetId, mergeClustersStore, selectCluster])

  return (
    <div style={{ display: 'flex', height: '100%', gap: '16px', padding: '16px' }}>
      {/* Cluster Grid */}
      <div style={{ flex: 1, overflow: 'auto', minWidth: 0 }}>
        <h3 style={{ color: '#e0e0e0', fontSize: '16px', marginBottom: '12px' }}>
          人脸聚类 ({clusters.length})
        </h3>
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(auto-fill, minmax(120px, 1fr))',
            gap: '10px',
          }}
        >
          {clusters.map((cluster) => (
            <div
              key={cluster.id}
              onClick={() => {
                handleSelectCluster(cluster)
                loadThumbnail(cluster.id)
              }}
              style={{
                background: selectedClusterId === cluster.id ? '#3a3a6e' : '#2a2a3e',
                border: selectedClusterId === cluster.id ? '2px solid #8080ff' : '2px solid transparent',
                borderRadius: '8px',
                padding: '10px',
                cursor: 'pointer',
                textAlign: 'center',
                transition: 'all 0.15s',
              }}
            >
              <div
                style={{
                  width: '80px',
                  height: '80px',
                  background: '#1a1a2e',
                  borderRadius: '6px',
                  margin: '0 auto 8px',
                  overflow: 'hidden',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                }}
              >
                {thumbnails[cluster.id] ? (
                  <img
                    src={`data:image/jpeg;base64,${thumbnails[cluster.id]}`}
                    alt={cluster.label}
                    style={{ width: '100%', height: '100%', objectFit: 'cover' }}
                  />
                ) : (
                  <span style={{ color: '#5050ff', fontSize: '24px' }}>{cluster.size}</span>
                )}
              </div>
              <div style={{ color: '#e0e0e0', fontSize: '12px', fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {cluster.label}
              </div>
              <div style={{ color: '#a0a0a0', fontSize: '11px', marginTop: '2px' }}>
                {cluster.size} 张人脸
              </div>
              {cluster.binding && (
                <div
                  style={{
                    background: '#2a4a2a',
                    color: '#80ff80',
                    fontSize: '10px',
                    padding: '2px 6px',
                    borderRadius: '4px',
                    marginTop: '4px',
                  }}
                >
                  {cluster.binding.roleName}
                </div>
              )}
            </div>
          ))}
        </div>
      </div>

      {/* Cluster Detail + Tag Editor */}
      <div style={{ width: '380px', background: '#1a1a2e', borderRadius: '10px', padding: '16px', overflow: 'auto', flexShrink: 0 }}>
        {selectedCluster ? (
          <>
            <h3 style={{ color: '#e0e0e0', fontSize: '16px', marginBottom: '4px' }}>
              {selectedCluster.label}
            </h3>
            <p style={{ color: '#a0a0a0', fontSize: '13px', marginBottom: '16px' }}>
              {selectedCluster.size} 个成员
            </p>

            {/* Member list */}
            <div style={{ marginBottom: '16px', maxHeight: '200px', overflow: 'auto' }}>
              {selectedCluster.members.map((m, idx) => (
                <div
                  key={`${m.photoId}-${idx}`}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: '8px',
                    padding: '6px 0',
                    borderBottom: '1px solid #2a2a3e',
                    fontSize: '12px',
                    color: '#c0c0c0',
                  }}
                >
                  <span style={{ color: '#5050ff' }}>#{idx + 1}</span>
                  <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {m.filename}
                  </span>
                  <span style={{ color: '#808080', fontSize: '11px' }}>
                    {(m.confidence * 100).toFixed(0)}%
                  </span>
                </div>
              ))}
            </div>

            {/* Tag Editor */}
            <div style={{ background: '#2a2a3e', borderRadius: '8px', padding: '12px', marginBottom: '12px' }}>
              <label style={{ color: '#a0a0a0', fontSize: '12px', display: 'block', marginBottom: '4px' }}>
                角色名称
              </label>
              <input
                value={roleName}
                onChange={(e) => setRoleName(e.target.value)}
                placeholder="例如: 张三"
                style={{
                  width: '100%',
                  padding: '8px 10px',
                  background: '#1a1a2e',
                  border: '1px solid #3a3a5e',
                  borderRadius: '6px',
                  color: '#e0e0e0',
                  fontSize: '13px',
                  boxSizing: 'border-box',
                  marginBottom: '10px',
                }}
              />
              <label style={{ color: '#a0a0a0', fontSize: '12px', display: 'block', marginBottom: '4px' }}>
                关键词 (逗号分隔)
              </label>
              <input
                value={keywords}
                onChange={(e) => setKeywords(e.target.value)}
                placeholder="例如: 人像, 户外, 微笑"
                style={{
                  width: '100%',
                  padding: '8px 10px',
                  background: '#1a1a2e',
                  border: '1px solid #3a3a5e',
                  borderRadius: '6px',
                  color: '#e0e0e0',
                  fontSize: '13px',
                  boxSizing: 'border-box',
                }}
              />
            </div>

            {/* Bind/Unbind buttons */}
            <div style={{ display: 'flex', gap: '8px', marginBottom: '12px' }}>
              <button
                onClick={handleBind}
                style={{
                  flex: 1,
                  padding: '8px',
                  background: 'linear-gradient(135deg, #5050ff, #8080ff)',
                  border: 'none',
                  borderRadius: '6px',
                  color: '#fff',
                  fontSize: '13px',
                  fontWeight: 600,
                  cursor: 'pointer',
                }}
              >
                {selectedCluster.binding ? '更新绑定' : '绑定'}
              </button>
              {selectedCluster.binding && (
                <button
                  onClick={handleUnbind}
                  style={{
                    padding: '8px 16px',
                    background: '#3a1a1a',
                    border: '1px solid #5a2a2a',
                    borderRadius: '6px',
                    color: '#ff8080',
                    fontSize: '13px',
                    cursor: 'pointer',
                  }}
                >
                  解绑
                </button>
              )}
            </div>

            {/* Merge */}
            <div style={{ background: '#2a2a3e', borderRadius: '8px', padding: '12px' }}>
              <label style={{ color: '#a0a0a0', fontSize: '12px', display: 'block', marginBottom: '6px' }}>
                合并到聚类
              </label>
              <div style={{ display: 'flex', gap: '6px' }}>
                <select
                  value={mergeTargetId ?? ''}
                  onChange={(e) => setMergeTargetId(e.target.value ? Number(e.target.value) : null)}
                  style={{
                    flex: 1,
                    padding: '6px 8px',
                    background: '#1a1a2e',
                    border: '1px solid #3a3a5e',
                    borderRadius: '6px',
                    color: '#e0e0e0',
                    fontSize: '12px',
                  }}
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
                  onClick={handleMerge}
                  disabled={!mergeTargetId}
                  style={{
                    padding: '6px 12px',
                    background: mergeTargetId ? '#2a4a2a' : '#2a2a3e',
                    border: '1px solid #3a5a3a',
                    borderRadius: '6px',
                    color: mergeTargetId ? '#80ff80' : '#606060',
                    fontSize: '12px',
                    cursor: mergeTargetId ? 'pointer' : 'not-allowed',
                  }}
                >
                  合并
                </button>
              </div>
            </div>
          </>
        ) : (
          <div style={{ color: '#606060', fontSize: '14px', textAlign: 'center', paddingTop: '40px' }}>
            选择一个聚类以查看详情
          </div>
        )}
      </div>
    </div>
  )
}
