import { create } from 'zustand'
import { settingsApi, type MLStatus } from '../api/settings'

interface SettingsStore {
  settings: Record<string, string>
  loading: boolean
  dirty: boolean
  mlStatus: MLStatus | null
  mlStatusLoading: boolean
  load: () => Promise<void>
  loadMlStatus: () => Promise<void>
  setSetting: (key: string, value: string) => Promise<void>
  resetToDefaults: () => Promise<void>
  reset: () => void
}

export const useSettingsStore = create<SettingsStore>((set, get) => ({
  settings: {},
  loading: false,
  dirty: false,
  mlStatus: null,
  mlStatusLoading: false,

  load: async () => {
    set({ loading: true })
    try {
      const settings = await settingsApi.getAll()
      set({ settings, loading: false, dirty: false })
    } catch (e) {
      console.error('Failed to load settings:', e)
      set({ loading: false, dirty: false })
    }
  },

  loadMlStatus: async () => {
    set({ mlStatusLoading: true })
    try {
      const mlStatus = await settingsApi.getMlStatus()
      set({ mlStatus, mlStatusLoading: false })
    } catch (e) {
      console.error('Failed to load ML status:', e)
      set({ mlStatusLoading: false })
    }
  },

  setSetting: async (key, value) => {
    await settingsApi.set(key, value)
    set((state) => ({
      settings: { ...state.settings, [key]: value },
      dirty: true,
    }))
  },

  resetToDefaults: async () => {
    const settings = await settingsApi.reset()
    set({ settings, dirty: false })
  },

  reset: () => set({ settings: {}, loading: false, dirty: false, mlStatus: null, mlStatusLoading: false }),
}))
