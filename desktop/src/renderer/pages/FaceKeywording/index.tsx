import React, { Suspense, lazy, useEffect } from 'react'
import { useParams } from 'react-router-dom'
import { useFaceKwStore } from './faceKwStore'
import { useTranslation, type TranslationKey } from '../../locales'
import styles from './FaceKeywording.module.css'

const StepAnalyze = lazy(() => import('./StepAnalyze'))
const StepReview = lazy(() => import('./StepReview'))
const StepWriteback = lazy(() => import('./StepWriteback'))

export default function FaceKeywording() {
  const { t } = useTranslation()
  const { sessionId } = useParams<{ sessionId: string }>()
  const { step, setStep, setSessionId, analysisStatus } = useFaceKwStore()

  useEffect(() => {
    // Deliberately NOT cancelling the previous session's analysis: jobs run
    // in the background by design (persisted, resumable after reload). Only
    // the local store switches to the new session.
    if (sessionId) setSessionId(sessionId)
  }, [sessionId, setSessionId])

  const steps: { key: string; labelKey: TranslationKey }[] = [
    { key: 'analyze', labelKey: 'face.analyzeStep' },
    { key: 'review', labelKey: 'face.reviewStep' },
    { key: 'writeback', labelKey: 'face.writebackStep' },
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
                {t(s.labelKey)}
              </button>
              {idx < steps.length - 1 && (
                <span className={styles.separator}>→</span>
              )}
            </React.Fragment>
          )
        })}
      </div>

      <div className={styles.content}>
        <Suspense fallback={<div className={styles.loading}>{t('face.loading')}</div>}>
          {step === 'analyze' && <StepAnalyze />}
          {step === 'review' && <StepReview />}
          {step === 'writeback' && <StepWriteback />}
        </Suspense>
      </div>
    </div>
  )
}
