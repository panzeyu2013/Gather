import { create } from 'zustand'

type PageName = 'dashboard' | 'similarity' | 'faceKw'
type EngineStatus = 'connecting' | 'ready' | 'disconnected'

interface SessionStore {
  currentSessionId: string | null
  currentPage: PageName
  engineStatus: EngineStatus
  setSession: (id: string | null) => void
  navigate: (page: PageName, sessionId?: string) => void
  setEngineStatus: (status: EngineStatus) => void
  reset: () => void
}

export const useSessionStore = create<SessionStore>((set) => ({
  currentSessionId: null,
  currentPage: 'dashboard',
  engineStatus: 'connecting',
  setSession: (id) => set({ currentSessionId: id }),
  navigate: (page, sessionId) => {
    set((state) => ({
      currentPage: page,
      currentSessionId: sessionId ?? state.currentSessionId,
    }))
  },
  setEngineStatus: (status) => set({ engineStatus: status }),
  reset: () => set({ currentSessionId: null, currentPage: 'dashboard', engineStatus: 'connecting' }),
}))
