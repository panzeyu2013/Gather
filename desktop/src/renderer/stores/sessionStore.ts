import { create } from 'zustand'

interface SessionStore {
  currentSessionId: string | null
  setSession: (id: string | null) => void
  reset: () => void
}

export const useSessionStore = create<SessionStore>((set) => ({
  currentSessionId: null,
  setSession: (id) => set({ currentSessionId: id }),
  reset: () => set({ currentSessionId: null }),
}))
