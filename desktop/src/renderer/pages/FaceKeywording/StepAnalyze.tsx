import React, { useState, useCallback, useEffect } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useFaceKwStore } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'
import { jobsApi } from '../../api/jobs'
import { useEvent } from '../../hooks/useEvent'
import type { FaceModelsStatusData, JobProgressData } from '@gather/shared'
import { useQueryClient } from '@tanstack/react-query'
import styles from './StepAnalyze.module.css'

const MODELS_GUIDANCE = '人脸模型未安装 → 打开设置自动下载（约 182 MB）'

// Subscribes only to the high-frequency progress fields (plus the running
// gate) so progress ticks re-render just the progress block, not the whole
// analyze step.
function AnalyzeProgress() {
  const analysisStatus = useFaceKwStore((s) => s.analysisStatus)
  const progressCurrent = useFaceKwStore((s) => s.progressCurrent)
  const progressTotal = useFaceKwStore((s) => s.progressTotal)
  const progressMessage = useFaceKwStore((s) => s.progressMessage)

  if (analysisStatus !== 'running') return null

  return (
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
  )
}

export default function StepAnalyze() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const navigate = useNavigate()
  const finishAnalysis = useFaceKwStore((s) => s.finishAnalysis)
  const analysisStatus = useFaceKwStore((s) => s.analysisStatus)
  const setAnalysisStatus = useFaceKwStore((s) => s.setAnalysisStatus)
  const setProgress = useFaceKwStore((s) => s.setProgress)
  const queryClient = useQueryClient()

  const [eps, setEps] = useState(0.6)
  const [minPts, setMinPts] = useState(3)
  const [error, setError] = useState<string | null>(null)
  const [modelsStatus, setModelsStatus] = useState<FaceModelsStatusData | null>(null)

  const modelsMissing = Boolean(
    modelsStatus && (!modelsStatus.detectorPresent || !modelsStatus.encoderPresent),
  )

  useEffect(() => {
    let mounted = true
    faceKwApi.modelsStatus()
      .then((status) => {
        if (mounted) setModelsStatus(status)
      })
      .catch((error) => {
        console.warn('Failed to query face model status', error)
        if (mounted) setModelsStatus(null)
      })
    return () => {
      mounted = false
    }
  }, [])

  const guidanceSuffix = modelsMissing ? `\n${MODELS_GUIDANCE}` : ''

  // On mount, recover an in-flight face analysis (e.g. after a renderer
  // reload) so the analyzing state and progress bar are restored.
  useEffect(() => {
    let disposed = false
    void (async () => {
      try {
        const jobs = await jobsApi.list()
        if (disposed) return
        const job = jobs.find(
          (candidate) =>
            candidate.type === 'face.analyze' &&
            candidate.scopeType === 'session' &&
            candidate.scopeId === sessionId &&
            ['queued', 'running', 'cancelling'].includes(candidate.status),
        )
        if (job) {
          setAnalysisStatus(sessionId!, 'running')
          setProgress(sessionId!, job.progressCurrent, job.progressTotal, job.progressMessage || '正在检测人脸...')
        }
      } catch {
        // Best-effort; push events will carry subsequent progress.
      }
    })()
    return () => {
      disposed = true
    }
  }, [sessionId, setAnalysisStatus, setProgress])

  // Live progress comes from the JobService channel; the legacy 'progress'
  // event only fires once when the IPC handler resolves, which would leave
  // the progress bar empty during the whole run.
  useEvent('jobs:progress', (payload) => {
    if (!sessionId) return
    const data = payload as JobProgressData
    if (
      data.jobType === 'face.analyze' &&
      data.scopeType === 'session' &&
      data.scopeId === sessionId
    ) {
      if (data.status) {
        if (data.status === 'succeeded') finishAnalysis(sessionId)
        else if (data.status === 'cancelled' || data.status === 'failed') {
          setAnalysisStatus(sessionId, data.status)
        } else if (data.status === 'interrupted') {
          setAnalysisStatus(sessionId, 'failed')
        }
        return
      }
      setProgress(sessionId, data.current, data.total, data.message || '正在检测人脸...')
      // Only flip the gate on the first tick: setting the same value on every
      // progress event relies on zustand's Object.is short-circuit, and this
      // keeps the running-gate logic explicit for AnalyzeProgress.
      if (useFaceKwStore.getState().analysisStatus !== 'running') {
        setAnalysisStatus(sessionId, 'running')
      }
    }
  }, Boolean(sessionId))

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
          `分析失败：检测失败 ${result.detectionFailures} 张，编码失败 ${result.encodingFailures} 个人脸${guidanceSuffix}`,
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
        const message = (e as Error).message
        setError(`${message}${guidanceSuffix}`)
        setAnalysisStatus(sessionId, 'failed')
      }
    }
  }, [sessionId, eps, minPts, setAnalysisStatus, finishAnalysis, queryClient, modelsMissing, guidanceSuffix])

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
      setError(`${error instanceof Error ? error.message : '重新聚类失败'}${guidanceSuffix}`)
      setAnalysisStatus(sessionId, 'failed')
    }
  }, [eps, minPts, sessionId, setAnalysisStatus, finishAnalysis, queryClient, guidanceSuffix])

  const isRunning = analysisStatus === 'running'

  return (
    <div className={styles.page}>
      <h2 className={styles.title}>人脸检测与聚类</h2>

      {modelsMissing && (
        <div className={styles.guidance}>
          <span className={styles.guidanceText}>{MODELS_GUIDANCE}</span>
          <button
            className={styles.guidanceButton}
            onClick={() => navigate('/settings')}
          >
            打开设置
          </button>
        </div>
      )}

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

      {isRunning && <AnalyzeProgress />}

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
