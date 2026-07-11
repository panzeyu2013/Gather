import { create } from 'zustand'

interface SimilarityState {
  threshold: number
  minGroupSize: number
  isAnalyzing: boolean
  progressCurrent: number
  progressTotal: number
  progressMessage: string
  setThreshold: (v: number) => void
  setMinGroupSize: (v: number) => void
  setIsAnalyzing: (v: boolean) => void
  setProgress: (current: number, total: number, message: string) => void
  reset: () => void
}

export const useSimilarityStore = create<SimilarityState>((set) => ({
  threshold: 10,
  minGroupSize: 2,
  isAnalyzing: false,
  progressCurrent: 0,
  progressTotal: 0,
  progressMessage: '',
  setThreshold: (threshold) => set({ threshold }),
  setMinGroupSize: (minGroupSize) => set({ minGroupSize }),
  setIsAnalyzing: (isAnalyzing) => set({ isAnalyzing }),
  setProgress: (current, total, message) => set({ progressCurrent: current, progressTotal: total, progressMessage: message }),
  reset: () => set({ threshold: 10, minGroupSize: 2, isAnalyzing: false, progressCurrent: 0, progressTotal: 0, progressMessage: '' }),
}))
