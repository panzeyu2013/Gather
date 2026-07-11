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
  clusters: ClusterData[]
  selectedClusterId: number | null
  writebackReport: string | null
  writebackRunning: boolean

  setSessionId: (id: string) => void
  setStep: (step: Step) => void
  setAnalysisStatus: (status: AnalysisStatus) => void
  setProgress: (current: number, total: number, message: string) => void
  setClusters: (clusters: ClusterData[]) => void
  selectCluster: (id: number | null) => void
  updateClusterBinding: (clusterId: number, binding: { roleName: string; keywords: string[] } | null) => void
  removeCluster: (clusterId: number) => void
  mergeClusters: (sourceId: number, targetId: number) => void
  setWritebackReport: (report: string | null) => void
  setWritebackRunning: (running: boolean) => void
  reset: () => void
}

export const useFaceKwStore = create<FaceKwState>((set) => ({
  step: 'analyze',
  sessionId: null,
  analysisStatus: 'idle',
  progressCurrent: 0,
  progressTotal: 0,
  progressMessage: '',
  clusters: [],
  selectedClusterId: null,
  writebackReport: null,
  writebackRunning: false,

  setSessionId: (id) => set({ sessionId: id, step: 'analyze', analysisStatus: 'idle', clusters: [], selectedClusterId: null }),
  setStep: (step) => set({ step }),
  setAnalysisStatus: (status) => set({ analysisStatus: status }),
  setProgress: (current, total, message) => set({ progressCurrent: current, progressTotal: total, progressMessage: message }),
  setClusters: (clusters) => set({ clusters, step: 'review', analysisStatus: 'done' }),
  selectCluster: (id) => set({ selectedClusterId: id }),
  updateClusterBinding: (clusterId, binding) =>
    set((state) => ({
      clusters: state.clusters.map((c) =>
        c.id === clusterId ? { ...c, binding, status: binding ? 'bound' : 'unbound' } : c,
      ),
    })),
  removeCluster: (clusterId) =>
    set((state) => ({
      clusters: state.clusters.filter((c) => c.id !== clusterId),
      selectedClusterId: state.selectedClusterId === clusterId ? null : state.selectedClusterId,
    })),
  mergeClusters: (sourceId, targetId) =>
    set((state) => {
      const source = state.clusters.find((c) => c.id === sourceId)
      const target = state.clusters.find((c) => c.id === targetId)
      if (!source || !target) return state
      const merged: ClusterData = {
        ...target,
        size: target.size + source.size,
        members: [...target.members, ...source.members],
      }
      return {
        clusters: state.clusters
          .filter((c) => c.id !== sourceId)
          .map((c) => (c.id === targetId ? merged : c)),
        selectedClusterId: state.selectedClusterId === sourceId ? targetId : state.selectedClusterId,
      }
    }),
  setWritebackReport: (report) => set({ writebackReport: report }),
  setWritebackRunning: (running) => set({ writebackRunning: running }),
  reset: () =>
    set({
      step: 'analyze',
      analysisStatus: 'idle',
      progressCurrent: 0,
      progressTotal: 0,
      progressMessage: '',
      clusters: [],
      selectedClusterId: null,
      writebackReport: null,
      writebackRunning: false,
    }),
}))
