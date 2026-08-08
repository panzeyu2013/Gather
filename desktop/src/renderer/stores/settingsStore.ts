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

// Debounce settings persistence: slider drags / fast typing fire many
// setSetting calls, and each one used to trigger an IPC write + disk flush.
// The in-memory settings object updates immediately (optimistic UI), while
// the persisted write is coalesced per key. Promises resolve once the write
// for that key has been flushed, so `await setSetting(...)` callers keep
// their ordering guarantees.
const SETTING_DEBOUNCE_MS = 250

const writeTimers = new Map<string, ReturnType<typeof setTimeout>>()
const pendingValues = new Map<string, string>()
// Value that was in memory before the first coalesced setSetting for a key,
// so a failed flush can roll the optimistic update back.
const pendingPreviousValues = new Map<string, string | undefined>()
const pendingResolvers = new Map<string, Array<{ resolve: () => void; reject: (error: unknown) => void }>>()
const inFlightWrites = new Map<string, Promise<void>>()
let resetting = false
const resetWaiters: Array<() => void> = []

export const useSettingsStore = create<SettingsStore>((set, get) => {
  const flushSetting = (key: string) => {
    writeTimers.delete(key)
    const value = pendingValues.get(key)
    pendingValues.delete(key)
    const previousValue = pendingPreviousValues.get(key)
    pendingPreviousValues.delete(key)
    const entries = pendingResolvers.get(key) ?? []
    pendingResolvers.delete(key)
    if (value === undefined) {
      entries.forEach((entry) => entry.resolve())
      return
    }
    // All callers coalesced into this write resolve/reject together, keeping
    // the debounce semantics: one IPC write, one outcome for every awaiter.
    const write = settingsApi.set(key, value)
    inFlightWrites.set(key, write.then(
      () => {
        entries.forEach((entry) => entry.resolve())
      },
      (error) => {
        console.error(`Failed to persist setting ${key}:`, error)
        // Roll the optimistic in-memory value back to the pre-write value so
        // the UI does not claim a setting that the database rejected.
        set((state) => {
          const next = { ...state.settings }
          if (previousValue === undefined) delete next[key]
          else next[key] = previousValue
          return {
            settings: next,
            ...(pendingValues.size === 0 && writeTimers.size === 0 ? { dirty: false } : {}),
          }
        })
        entries.forEach((entry) => entry.reject(error))
      },
    ).finally(() => inFlightWrites.delete(key)))
  }

  // Resolves once any pending (or in-flight) write for `key` has landed, so
  // callers like loadMlStatus do not read a stale value from the database
  // before the debounced write flushed.
  const waitForPendingWrite = (key: string): Promise<void> => {
    const inFlight = inFlightWrites.get(key)
    if (inFlight) return inFlight.catch(() => undefined)
    if (!pendingValues.has(key)) return Promise.resolve()
    return new Promise<void>((resolve) => {
      const entries = pendingResolvers.get(key) ?? []
      entries.push({ resolve, reject: () => undefined })
      pendingResolvers.set(key, entries)
    })
  }

  const cancelPendingWrites = () => {
    for (const timer of writeTimers.values()) clearTimeout(timer)
    writeTimers.clear()
    pendingValues.clear()
    pendingPreviousValues.clear()
    const entries = [...pendingResolvers.values()].flat()
    pendingResolvers.clear()
    entries.forEach((entry) => entry.resolve())
  }

  // Flush everything still sitting in a debounce timer when the app is going
  // away: the timers die with the renderer process, so without this the last
  // 250ms of edits would be lost. The IPC write is async but the request is
  // sent before teardown completes (best effort).
  const flushAllPending = () => {
    for (const key of [...writeTimers.keys()]) {
      flushSetting(key)
    }
  }
  if (typeof window !== 'undefined') {
    window.addEventListener('beforeunload', flushAllPending)
    window.addEventListener('pagehide', flushAllPending)
  }

  return {
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
        // Model paths are persisted with the 250ms debounce; a blur-triggered
        // status read must not hit the database before the write landed.
        await waitForPendingWrite('detector_model_path')
        await waitForPendingWrite('encoder_model_path')
        const mlStatus = await settingsApi.getMlStatus()
        set({ mlStatus, mlStatusLoading: false })
      } catch (e) {
        console.error('Failed to load ML status:', e)
        set({ mlStatusLoading: false })
      }
    },

    setSetting: async (key, value) => {
      // While resetToDefaults is in flight, defer the call until the reset has
      // landed; otherwise the write would be scheduled against the pre-reset
      // window and flush AFTER the reset, leaving the database with the
      // user's value while memory shows the defaults.
      if (resetting) {
        await new Promise<void>((resolve) => { resetWaiters.push(resolve) })
      }
      if (!pendingPreviousValues.has(key)) {
        pendingPreviousValues.set(key, get().settings[key])
      }
      set((state) => ({
        settings: { ...state.settings, [key]: value },
        dirty: true,
      }))
      await new Promise<void>((resolve, reject) => {
        const entries = pendingResolvers.get(key) ?? []
        entries.push({ resolve, reject })
        pendingResolvers.set(key, entries)
        pendingValues.set(key, value)
        const existing = writeTimers.get(key)
        if (existing) clearTimeout(existing)
        writeTimers.set(key, setTimeout(() => flushSetting(key), SETTING_DEBOUNCE_MS))
      })
    },

    resetToDefaults: async () => {
      resetting = true
      cancelPendingWrites()
      try {
        const settings = await settingsApi.reset()
        set({ settings, dirty: false })
      } finally {
        resetting = false
        const waiters = resetWaiters.splice(0)
        waiters.forEach((resolve) => resolve())
      }
    },

    reset: () => {
      cancelPendingWrites()
      set({ settings: {}, loading: false, dirty: false, mlStatus: null, mlStatusLoading: false })
    },
  }
})
