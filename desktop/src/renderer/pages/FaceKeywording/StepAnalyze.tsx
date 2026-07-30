import React, { useState, useCallback, useEffect } from 'react'
import { useParams } from 'react-router-dom'
import { useFaceKwStore } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'
import { onProgress } from '../../api/client'
import type { ProgressData } from '@gather/shared'
import { useQueryClient } from '@tanstack/react-query'
import styles from './StepAnalyze.module.css'

export default function StepAnalyze() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const {
    finishAnalysis,
    analysisStatus,
    setAnalysisStatus,
    progressCurrent,
    progressTotal,
    progressMessage,
    setProgress,
  } = useFaceKwStore()
  const queryClient = useQueryClient()

  const [eps, setEps] = useState(0.6)
  const [minPts, setMinPts] = useState(3)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    return onProgress((data) => {
      const p = data as ProgressData
      if (p.sessionId && p.sessionId !== sessionId) return
      if (p.current !== undefined && p.total !== undefined) {
        setProgress(sessionId!, p.current, p.total, p.message ?? '')
        if (p.status) setAnalysisStatus(sessionId!, p.status)
      }
    })
  }, [sessionId, setProgress, setAnalysisStatus])

  const handleAnalyze = useCallback(async () => {
    if (!sessionId) return
    setError(null)
    setAnalysisStatus(sessionId, 'running')
    try {
      const result = await faceKwApi.analyze(sessionId, {
        eps,
        minSamples: minPts,
      })
      if (result.status === 'cancelled') {
        setAnalysisStatus(sessionId, 'cancelled')
        return
      }
      if (result.status === 'failed') {
        setError(
          `分析失败：检测失败 ${result.detectionFailures} 张，编码失败 ${result.encodingFailures} 个人脸`,
        )
        setAnalysisStatus(sessionId, 'failed')
        return
      }
      await queryClient.invalidateQueries({ queryKey: ['face-clusters', sessionId] })
      finishAnalysis(sessionId)
    } catch (e) {
      if ((e as Error).message?.includes('cancelled')) {
        setAnalysisStatus(sessionId, 'cancelled')
      } else {
        setError((e as Error).message)
        setAnalysisStatus(sessionId, 'failed')
      }
    }
  }, [sessionId, eps, minPts, setAnalysisStatus, finishAnalysis, queryClient])

  const handleCancel = useCallback(async () => {
    if (!sessionId) return
    try {
      await faceKwApi.cancel(sessionId)
    } catch {
      // ignore cancel errors
    }
  }, [sessionId])

  const handleRecluster = useCallback(async () => {
    if (!sessionId) return
    setError(null)
    setAnalysisStatus(sessionId, 'running')
    try {
      await faceKwApi.recluster(sessionId, eps, minPts)
      await queryClient.invalidateQueries({ queryKey: ['face-clusters', sessionId] })
      finishAnalysis(sessionId)
    } catch (error) {
      setError(error instanceof Error ? error.message : '重新聚类失败')
      setAnalysisStatus(sessionId, 'failed')
    }
  }, [eps, minPts, sessionId, setAnalysisStatus, finishAnalysis, queryClient])

  const isRunning = analysisStatus === 'running'

  return (
    <div className={styles.page}>
      <h2 className={styles.title}>人脸检测与聚类</h2>

      <div className={styles.panel}>
      <div className={styles.field}>
        <label className={styles.label}>
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
          className={styles.slider}
          style={{
            background: `linear-gradient(to right, var(--color-primary) 0%, var(--color-primary) ${((eps - 0.3) / 0.65) * 100}%, var(--color-border) ${((eps - 0.3) / 0.65) * 100}%, var(--color-border) 100%)`,
          }}
        />
        <span className={styles.value}>{eps.toFixed(2)}</span>
      </div>

      <div className={styles.field}>
        <label className={styles.label}>
          最小聚类数
        </label>
        <input
          type="number"
          min={2}
          max={20}
          value={minPts}
          onChange={(e) => setMinPts(parseInt(e.target.value, 10) || 3)}
          disabled={isRunning}
          className={styles.numberInput}
        />
      </div>

      {error && (
        <div className={styles.error}>
          {error}
        </div>
      )}

      {isRunning && (
        <div className={styles.progress}>
          <div className={styles.progressText}>
            {progressMessage} {progressTotal > 0 ? `(${progressCurrent}/${progressTotal})` : ''}
          </div>
          {progressTotal > 0 && (
            <div className={styles.progressTrack}>
              <div
                className={styles.progressFill}
                style={{
                  width: `${Math.min(100, (progressCurrent / progressTotal) * 100)}%`,
                }}
              />
            </div>
          )}
        </div>
      )}

      <div className={styles.actions}>
        {analysisStatus === 'idle' || analysisStatus === 'failed' || analysisStatus === 'cancelled' ? (
          <button
            onClick={handleAnalyze}
            className={styles.button}
          >
            开始分析
          </button>
        ) : null}
        {analysisStatus === 'done' ? (
          <button onClick={handleRecluster} className={styles.button}>
            仅重新聚类
          </button>
        ) : null}
        {isRunning && (
          <button
            onClick={handleCancel}
            className={styles.cancelButton}
          >
            取消
          </button>
        )}
      </div>
      </div>
    </div>
  )
}
