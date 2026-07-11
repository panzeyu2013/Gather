import React, { useState, useMemo } from 'react'
import { useFaceKwStore } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'
import WritebackReport from '../../components/WritebackReport/WritebackReport'
import type { WritebackResult, WritebackItem } from '@gather/shared'

export default function StepWriteback() {
  const { clusters, selectedClusterId, setWritebackReport, writebackReport, writebackRunning, setWritebackRunning, sessionId } = useFaceKwStore()
  const [writebackResult, setWritebackResult] = useState<WritebackResult | null>(null)
  const [failedItems, setFailedItems] = useState<WritebackItem[]>([])

  const boundClusters = useMemo(() => clusters.filter((c) => c.binding), [clusters])
  const unboundClusters = useMemo(() => clusters.filter((c) => !c.binding), [clusters])

  const totalAffected = useMemo(
    () => boundClusters.reduce((sum, c) => sum + c.size, 0),
    [boundClusters],
  )

  const handlePreview = async () => {
    if (!sessionId) return
    try {
      const preview = await faceKwApi.previewWriteback(sessionId)
      setWritebackReport(`预览: ${preview.totalCount} 项, ${preview.affectedPhotos} 张照片受影响`)
    } catch (e) {
      setWritebackReport(`预览失败: ${(e as Error).message}`)
    }
  }

  const handleExecute = async () => {
    if (!sessionId) return
    setWritebackRunning(true)
    try {
      const preview = await faceKwApi.previewWriteback(sessionId)
      const result = await faceKwApi.writeback(sessionId, preview.items)
      setWritebackResult(result)
      setFailedItems(result.failedItems)
      setWritebackReport(`写回完成: ${result.written} 已写入, ${result.failed} 失败, ${result.skipped} 已跳过`)
    } catch (e) {
      setWritebackReport(`写回失败: ${(e as Error).message}`)
    } finally {
      setWritebackRunning(false)
    }
  }

  const handleRetryFailed = async () => {
    if (!sessionId) return
    setWritebackRunning(true)
    try {
      setWritebackReport('正在重试失败项...')
      const failedOnly = failedItems
      const result = await faceKwApi.writeback(sessionId, failedOnly)
      setWritebackResult(result)
      if (result.failed === 0) setFailedItems([])
    } catch (e) {
      setWritebackReport(`重试失败: ${(e as Error).message}`)
    } finally {
      setWritebackRunning(false)
    }
  }

  const handleConfirmSync = async () => {
    if (!sessionId) return
    try {
      await faceKwApi.confirmSync(sessionId)
      setWritebackReport('同步已确认。')
    } catch (e) {
      setWritebackReport(`确认失败: ${(e as Error).message}`)
    }
  }

  const handleCleanup = async () => {
    if (!sessionId) return
    try {
      const result = await faceKwApi.cleanup(sessionId)
      setWritebackReport(`清理完成: ${result.deletedCount} 个文件已删除`)
    } catch (e) {
      setWritebackReport(`清理失败: ${(e as Error).message}`)
    }
  }

  return (
    <div style={{ padding: '32px', maxWidth: '700px', margin: '0 auto' }}>
      <h2 style={{ color: '#e0e0e0', fontSize: '20px', marginBottom: '24px' }}>写回</h2>

      <div style={{ marginBottom: '20px', display: 'flex', gap: '16px' }}>
        <div
          style={{
            flex: 1,
            background: '#2a2a3e',
            borderRadius: '10px',
            padding: '16px',
            textAlign: 'center',
          }}
        >
          <div style={{ color: '#8080ff', fontSize: '28px', fontWeight: 700 }}>{boundClusters.length}</div>
          <div style={{ color: '#a0a0a0', fontSize: '12px', marginTop: '4px' }}>已绑定聚类</div>
        </div>
        <div
          style={{
            flex: 1,
            background: '#2a2a3e',
            borderRadius: '10px',
            padding: '16px',
            textAlign: 'center',
          }}
        >
          <div style={{ color: '#e0e0e0', fontSize: '28px', fontWeight: 700 }}>{totalAffected}</div>
          <div style={{ color: '#a0a0a0', fontSize: '12px', marginTop: '4px' }}>受影响照片</div>
        </div>
        <div
          style={{
            flex: 1,
            background: '#2a2a3e',
            borderRadius: '10px',
            padding: '16px',
            textAlign: 'center',
          }}
        >
          <div style={{ color: '#ff8080', fontSize: '28px', fontWeight: 700 }}>{unboundClusters.length}</div>
          <div style={{ color: '#a0a0a0', fontSize: '12px', marginTop: '4px' }}>已跳过</div>
        </div>
      </div>

      {/* Preview list */}
      <div style={{ marginBottom: '20px', maxHeight: '240px', overflow: 'auto', background: '#2a2a3e', borderRadius: '8px', padding: '12px' }}>
        {boundClusters.map((c) => (
          <div key={c.id} style={{ marginBottom: '12px' }}>
            <div style={{ color: '#8080ff', fontSize: '13px', fontWeight: 600, marginBottom: '4px' }}>
              {c.binding!.roleName} ({c.size} 张照片)
              <span style={{ color: '#a0a0a0', fontSize: '11px', marginLeft: '8px' }}>
                {c.binding!.keywords.join(', ')}
              </span>
            </div>
            {c.members.slice(0, 5).map((m, idx) => (
              <div key={idx} style={{ color: '#808080', fontSize: '11px', paddingLeft: '12px' }}>
                {m.filename}
              </div>
            ))}
            {c.members.length > 5 && (
              <div style={{ color: '#505050', fontSize: '11px', paddingLeft: '12px' }}>
                ... 及其他 {c.members.length - 5} 张
              </div>
            )}
          </div>
        ))}
        {boundClusters.length === 0 && (
          <div style={{ color: '#606060', fontSize: '13px', textAlign: 'center', padding: '20px' }}>
            没有已绑定的聚类可写回。请先绑定聚类。
          </div>
        )}
      </div>

      {/* Action buttons */}
      <div style={{ display: 'flex', gap: '12px', marginBottom: '20px' }}>
        <button
          onClick={handlePreview}
          style={{
            padding: '10px 28px',
            background: '#2a2a3e',
            border: '1px solid #3a3a5e',
            borderRadius: '8px',
            color: '#c0c0c0',
            fontSize: '14px',
            fontWeight: 600,
            cursor: 'pointer',
          }}
        >
          预览
        </button>
        <button
          onClick={handleExecute}
          disabled={boundClusters.length === 0 || writebackRunning}
          style={{
            padding: '10px 28px',
            background: boundClusters.length > 0 ? 'linear-gradient(135deg, #5050ff, #8080ff)' : '#2a2a3e',
            border: 'none',
            borderRadius: '8px',
            color: boundClusters.length > 0 ? '#fff' : '#606060',
            fontSize: '14px',
            fontWeight: 600,
            cursor: boundClusters.length > 0 ? 'pointer' : 'not-allowed',
          }}
        >
          {writebackRunning ? '写入中...' : '执行写回'}
        </button>
      </div>

      {/* Report */}
      {writebackReport && <WritebackReport
        result={writebackResult}
        failedItems={failedItems}
        onRetryFailed={handleRetryFailed}
        onConfirmSync={handleConfirmSync}
        onCleanup={handleCleanup}
      />}
    </div>
  )
}
