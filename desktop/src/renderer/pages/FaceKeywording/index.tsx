import React, { Suspense, lazy, useEffect, useRef } from 'react'
import { useParams } from 'react-router-dom'
import { useFaceKwStore } from './faceKwStore'
import { faceKwApi } from '../../api/faceKw'
import styles from './FaceKeywording.module.css'

const StepAnalyze = lazy(() => import('./StepAnalyze'))
const StepReview = lazy(() => import('./StepReview'))
const StepWriteback = lazy(() => import('./StepWriteback'))

export default function FaceKeywording() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const { step, setStep, setSessionId, analysisStatus } = useFaceKwStore()
  const prevSessionRef = useRef(sessionId)

  useEffect(() => {
    if (prevSessionRef.current && prevSessionRef.current !== sessionId) {
      faceKwApi.cancel(prevSessionRef.current).catch(() => {})
    }
    prevSessionRef.current = sessionId
    if (sessionId) setSessionId(sessionId)
  }, [sessionId, setSessionId])

  const steps: { key: string; label: string }[] = [
    { key: 'analyze', label: '分析' },
    { key: 'review', label: '审核' },
    { key: 'writeback', label: '写回' },
  ]

  const currentIdx = steps.findIndex((s) => s.key === step)

  return (
    <div className={styles.page}>
      <div className={styles.steps}>
        {steps.map((s, idx) => {
          const isActive = idx === currentIdx
          const isPast = idx < currentIdx
          const isClickable = isPast || (idx === currentIdx + 1 && analysisStatus === 'done')
          return (
            <React.Fragment key={s.key}>
              <button
                onClick={() => isClickable && setStep(s.key as 'analyze' | 'review' | 'writeback')}
                disabled={!isClickable && !isActive}
                className={isActive ? styles.stepActive : isPast ? styles.stepPast : styles.step}
              >
                {s.label}
              </button>
              {idx < steps.length - 1 && (
                <span className={styles.separator}>→</span>
              )}
            </React.Fragment>
          )
        })}
      </div>

      <div className={styles.content}>
        <Suspense fallback={<div className={styles.loading}>加载中...</div>}>
          {step === 'analyze' && <StepAnalyze />}
          {step === 'review' && <StepReview />}
          {step === 'writeback' && <StepWriteback />}
        </Suspense>
      </div>
    </div>
  )
}
