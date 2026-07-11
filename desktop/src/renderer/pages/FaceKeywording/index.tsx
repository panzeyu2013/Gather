import React, { Suspense, lazy } from 'react'
import { useParams } from 'react-router-dom'
import { useFaceKwStore } from './faceKwStore'

const StepAnalyze = lazy(() => import('./StepAnalyze'))
const StepReview = lazy(() => import('./StepReview'))
const StepWriteback = lazy(() => import('./StepWriteback'))

export default function FaceKeywording() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const { step, setStep, analysisStatus } = useFaceKwStore()

  const steps: { key: string; label: string }[] = [
    { key: 'analyze', label: '分析' },
    { key: 'review', label: '审核' },
    { key: 'writeback', label: '写回' },
  ]

  const currentIdx = steps.findIndex((s) => s.key === step)

  return (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      {/* Step indicator */}
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          gap: '8px',
          padding: '16px 24px',
          borderBottom: '1px solid #2a2a3e',
        }}
      >
        {steps.map((s, idx) => {
          const isActive = idx === currentIdx
          const isPast = idx < currentIdx
          const isClickable = isPast || (idx === currentIdx + 1 && analysisStatus === 'done')
          return (
            <React.Fragment key={s.key}>
              <button
                onClick={() => isClickable && setStep(s.key as 'analyze' | 'review' | 'writeback')}
                disabled={!isClickable && !isActive}
                style={{
                  padding: '6px 16px',
                  borderRadius: '20px',
                  fontSize: '13px',
                  fontWeight: isActive ? 600 : 400,
                  border: isActive ? '2px solid #8080ff' : '2px solid transparent',
                  background: isActive ? '#2a2a4e' : isPast ? '#1e2a1e' : 'transparent',
                  color: isActive ? '#c0c0ff' : isPast ? '#80c080' : '#505050',
                  cursor: isClickable || isActive ? 'pointer' : 'default',
                  opacity: isActive || isClickable || isPast ? 1 : 0.4,
                }}
              >
                {s.label}
              </button>
              {idx < steps.length - 1 && (
                <span style={{ color: '#3a3a5e', fontSize: '14px' }}>→</span>
              )}
            </React.Fragment>
          )
        })}
      </div>

      {/* Step content */}
      <div style={{ flex: 1, overflow: 'auto' }}>
        <Suspense fallback={<div style={{ padding: '32px', color: '#a0a0a0' }}>加载中...</div>}>
          {step === 'analyze' && <StepAnalyze />}
          {step === 'review' && <StepReview />}
          {step === 'writeback' && <StepWriteback />}
        </Suspense>
      </div>
    </div>
  )
}
