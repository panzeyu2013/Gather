import { create } from 'zustand'

type EngineStatus = 'connecting' | 'ready' | 'disconnected'

interface SessionStore {
  currentSessionId: string | null
  engineStatus: EngineStatus
  setSession: (id: string | null) => void
  setEngineStatus: (status: EngineStatus) => void
  reset: () => void
}

export const useSessionStore = create<SessionStore>((set) => ({
  currentSessionId: null,
  engineStatus: 'connecting',
  setSession: (id) => set({ currentSessionId: id }),
  setEngineStatus: (status) => set({ engineStatus: status }),
  reset: () => set({ currentSessionId: null, engineStatus: 'connecting' }),
}))
