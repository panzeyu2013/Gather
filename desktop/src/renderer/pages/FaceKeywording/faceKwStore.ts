import { create } from 'zustand'
import type { AnalysisStatus } from '@gather/shared'

export interface ClusterData {
  id: number
  label: string
  size: number
  status: string
  binding: { roleName: string; keywords: string[] } | null
  thumbnailPhotoId?: string
  members: ClusterMemberData[]
}

export interface ClusterMemberData {
  memberId: number
  photoId: string
  photoPath: string
  filename: string
  bbox: number[]
  confidence: number
}

export type Step = 'analyze' | 'review' | 'writeback'

interface FaceKwState {
  step: Step
  sessionId: string | null
  analysisStatus: AnalysisStatus
  progressCurrent: number
  progressTotal: number
  progressMessage: string
  selectedClusterId: number | null
  writebackReport: string | null
  writebackRunning: boolean

  setSessionId: (id: string) => void
  setStep: (step: Step) => void
  setAnalysisStatus: (sessionId: string, status: AnalysisStatus) => void
  setProgress: (sessionId: string, current: number, total: number, message: string) => void
  finishAnalysis: (sessionId: string) => void
  selectCluster: (sessionId: string, id: number | null) => void
  setWritebackReport: (sessionId: string, report: string | null) => void
  setWritebackRunning: (sessionId: string, running: boolean) => void
  reset: () => void
}

export const useFaceKwStore = create<FaceKwState>((set) => ({
  step: 'analyze',
  sessionId: null,
  analysisStatus: 'idle',
  progressCurrent: 0,
  progressTotal: 0,
  progressMessage: '',
  selectedClusterId: null,
  writebackReport: null,
  writebackRunning: false,

  setSessionId: (id) => set((state) => {
    if (state.sessionId === id) return state
    return {
      sessionId: id,
      step: 'analyze',
      analysisStatus: 'idle',
      progressCurrent: 0,
      progressTotal: 0,
      progressMessage: '',
      selectedClusterId: null,
      writebackReport: null,
      writebackRunning: false,
    }
  }),
  setStep: (step) => set({ step }),
  setAnalysisStatus: (sessionId, status) => set((state) => {
    if (state.sessionId !== sessionId) return state
    return { analysisStatus: status }
  }),
  setProgress: (sessionId, current, total, message) => set((state) => {
    if (state.sessionId !== sessionId) return state
    return { progressCurrent: current, progressTotal: total, progressMessage: message }
  }),
  finishAnalysis: (sessionId) => set((state) => {
    if (state.sessionId !== sessionId) return state
    return { step: 'review', analysisStatus: 'done' }
  }),
  selectCluster: (sessionId, id) => set((state) => {
    if (state.sessionId !== sessionId) return state
    return { selectedClusterId: id }
  }),
  setWritebackReport: (sessionId, report) => set((state) => {
    if (state.sessionId !== sessionId) return state
    return { writebackReport: report }
  }),
  setWritebackRunning: (sessionId, running) => set((state) => {
    if (state.sessionId !== sessionId) return state
    return { writebackRunning: running }
  }),
  reset: () =>
    set({
      step: 'analyze',
      analysisStatus: 'idle',
      progressCurrent: 0,
      progressTotal: 0,
      progressMessage: '',
      selectedClusterId: null,
      writebackReport: null,
      writebackRunning: false,
    }),
}))
