import React, { useState, useCallback, useEffect } from 'react'
import { useParams } from 'react-router-dom'
import { useFaceKwStore } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'
import { onProgress } from '../../api/client'
import type { ProgressData } from '@gather/shared'

export default function StepAnalyze() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const {
    setSessionId,
    setClusters,
    analysisStatus,
    setAnalysisStatus,
    progressCurrent,
    progressTotal,
    progressMessage,
    setProgress,
  } = useFaceKwStore()

  const [eps, setEps] = useState(0.6)
  const [minPts, setMinPts] = useState(3)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (sessionId) setSessionId(sessionId)
  }, [sessionId, setSessionId])

  useEffect(() => {
    return onProgress((data) => {
      const p = data as ProgressData
      if (p.current !== undefined && p.total !== undefined) {
        setProgress(p.current, p.total, p.message ?? '')
        if (p.status) setAnalysisStatus(p.status)
      }
    })
  }, [setProgress, setAnalysisStatus])

  const handleAnalyze = useCallback(async () => {
    if (!sessionId) return
    setError(null)
    setAnalysisStatus('running')
    try {
      await faceKwApi.analyze(sessionId, { eps, minSamples: minPts })
      const clusters = await faceKwApi.getClusters(sessionId)
      setClusters(clusters.map((c) => ({ ...c, binding: c.binding ?? null })))
    } catch (e) {
      if ((e as Error).message?.includes('cancelled')) {
        setAnalysisStatus('cancelled')
      } else {
        setError((e as Error).message)
        setAnalysisStatus('failed')
      }
    }
  }, [sessionId, eps, minPts, setAnalysisStatus, setClusters])

  const handleCancel = useCallback(async () => {
    if (!sessionId) return
    try {
      await faceKwApi.cancel(sessionId)
    } catch {
      // ignore cancel errors
    }
  }, [sessionId])

  const isRunning = analysisStatus === 'running'

  return (
    <div style={{ padding: '32px', maxWidth: '600px', margin: '0 auto' }}>
      <h2 style={{ color: '#e0e0e0', fontSize: '20px', marginBottom: '24px' }}>人脸检测与聚类</h2>

      <div style={{ marginBottom: '20px' }}>
        <label style={{ display: 'block', color: '#a0a0a0', marginBottom: '6px', fontSize: '13px' }}>
          相似度阈值 (EPS)
        </label>
        <input
          type="range"
          min="0.3"
          max="0.95"
          step="0.05"
          value={eps}
          onChange={(e) => setEps(parseFloat(e.target.value))}
          disabled={isRunning}
          style={{ width: '100%' }}
        />
        <span style={{ color: '#8080ff', fontSize: '13px' }}>{eps.toFixed(2)}</span>
      </div>

      <div style={{ marginBottom: '28px' }}>
        <label style={{ display: 'block', color: '#a0a0a0', marginBottom: '6px', fontSize: '13px' }}>
          最小聚类数
        </label>
        <input
          type="number"
          min={2}
          max={20}
          value={minPts}
          onChange={(e) => setMinPts(parseInt(e.target.value, 10) || 3)}
          disabled={isRunning}
          style={{
            padding: '8px 12px',
            background: '#2a2a3e',
            border: '1px solid #3a3a5e',
            borderRadius: '6px',
            color: '#e0e0e0',
            fontSize: '14px',
            width: '80px',
          }}
        />
      </div>

      {error && (
        <div style={{ background: '#3a1a1a', color: '#ff8080', padding: '12px', borderRadius: '6px', marginBottom: '16px', fontSize: '13px' }}>
          {error}
        </div>
      )}

      {isRunning && (
        <div style={{ marginBottom: '16px' }}>
          <div style={{ color: '#a0a0a0', fontSize: '13px', marginBottom: '8px' }}>
            {progressMessage} {progressTotal > 0 ? `(${progressCurrent}/${progressTotal})` : ''}
          </div>
          {progressTotal > 0 && (
            <div style={{ background: '#2a2a3e', borderRadius: '6px', height: '8px', overflow: 'hidden' }}>
              <div
                style={{
                  background: 'linear-gradient(90deg, #5050ff, #8080ff)',
                  height: '100%',
                  width: `${Math.min(100, (progressCurrent / progressTotal) * 100)}%`,
                  transition: 'width 0.2s',
                }}
              />
            </div>
          )}
        </div>
      )}

      <div style={{ display: 'flex', gap: '12px' }}>
        {analysisStatus === 'idle' || analysisStatus === 'failed' || analysisStatus === 'cancelled' ? (
          <button
            onClick={handleAnalyze}
            style={{
              padding: '10px 28px',
              background: 'linear-gradient(135deg, #5050ff, #8080ff)',
              border: 'none',
              borderRadius: '8px',
              color: '#fff',
              fontSize: '14px',
              fontWeight: 600,
              cursor: 'pointer',
            }}
          >
            开始分析
          </button>
        ) : null}
        {isRunning && (
          <button
            onClick={handleCancel}
            style={{
              padding: '10px 28px',
              background: '#3a1a1a',
              border: '1px solid #5a2a2a',
              borderRadius: '8px',
              color: '#ff8080',
              fontSize: '14px',
              fontWeight: 600,
              cursor: 'pointer',
            }}
          >
            取消
          </button>
        )}
      </div>
    </div>
  )
}
