import React, { useState, useCallback, useEffect } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useFaceKwStore } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'
import { jobsApi } from '../../api/jobs'
import { useEvent } from '../../hooks/useEvent'
import type { FaceModelsStatusData, JobProgressData } from '@gather/shared'
import { useQueryClient } from '@tanstack/react-query'
import { useTranslation } from '../../locales'
import { translateError } from '../../utils/errors'
import { translatePhase } from '../../utils/progress'
import styles from './StepAnalyze.module.css'

export default function StepAnalyze() {
  const { t } = useTranslation()
  const { sessionId } = useParams<{ sessionId: string }>()
  const navigate = useNavigate()
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

  const guidanceSuffix = modelsMissing ? `\n${t('face.modelsGuidance')}` : ''

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
          setProgress(sessionId!, job.progressCurrent, job.progressTotal, job.progressMessage || 'face.detecting')
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
      setProgress(sessionId, data.current, data.total, data.phase || data.message || 'face.detecting')
      setAnalysisStatus(sessionId, 'running')
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
          t('face.analyzeFailed', { detect: result.detectionFailures, encode: result.encodingFailures }) + guidanceSuffix,
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
      setError(`${error instanceof Error ? translateError(error) : t('face.reclusterFailed')}${guidanceSuffix}`)
      setAnalysisStatus(sessionId, 'failed')
    }
  }, [eps, minPts, sessionId, setAnalysisStatus, finishAnalysis, queryClient, guidanceSuffix])

  const isRunning = analysisStatus === 'running'

  return (
    <div className={styles.page}>
      <h2 className={styles.title}>{t('face.title')}</h2>

      {modelsMissing && (
        <div className={styles.guidance}>
          <span className={styles.guidanceText}>{t('face.modelsGuidance')}</span>
          <button
            className={styles.guidanceButton}
            onClick={() => navigate('/settings')}
          >
            {t('face.openSettings')}
          </button>
        </div>
      )}

      <div className={styles.panel}>
      <div className={styles.field}>
        <label className={styles.label}>
          {t('face.epsLabel')}
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
          {t('face.minClusterLabel')}
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
            {translatePhase(progressMessage)} {progressTotal > 0 ? `(${progressCurrent}/${progressTotal})` : ''}
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
            {t('face.startAnalyze')}
          </button>
        ) : null}
        {analysisStatus === 'done' ? (
          <button onClick={handleRecluster} className={styles.button}>
            {t('face.onlyRecluster')}
          </button>
        ) : null}
        {isRunning && (
          <button
            onClick={handleCancel}
            className={styles.cancelButton}
          >
            {t('common.cancel')}
          </button>
        )}
      </div>
      </div>
    </div>
  )
}
