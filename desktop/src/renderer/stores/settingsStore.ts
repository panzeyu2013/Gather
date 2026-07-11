import { create } from 'zustand'
import { settingsApi } from '../api/settings'

interface SettingsStore {
  settings: Record<string, string>
  loading: boolean
  dirty: boolean
  load: () => Promise<void>
  setSetting: (key: string, value: string) => Promise<void>
  resetToDefaults: () => Promise<void>
  reset: () => void
}

export const useSettingsStore = create<SettingsStore>((set, get) => ({
  settings: {},
  loading: false,
  dirty: false,

  load: async () => {
    set({ loading: true })
    try {
      const settings = await settingsApi.getAll()
      set({ settings, loading: false, dirty: false })
    } catch {
      set({ loading: false, dirty: false })
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

  reset: () => set({ settings: {}, loading: false, dirty: false }),
}))
