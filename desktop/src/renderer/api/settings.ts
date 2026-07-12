import { sendCommand } from './client'

export interface MLStatus {
  platform: string
  autoBackend: string
  autoBackendLabel: string
  provider: string
  isAuto: boolean
  availableBackends: Array<{ value: string; label: string }>
  modelResourcesDir: string
  detectorModel: { path: string; resolvedPath: string; exists: boolean }
  encoderModel: { path: string; resolvedPath: string; exists: boolean }
  modelInfo: {
    detectInputSize: number
    encoderInputSize: number
    embeddingDim: number
  }
}

export const settingsApi = {
  getAll: () => sendCommand<Record<string, string>>('settings.get_all', {}),
  get: (key: string) => sendCommand<string>('settings.get', { key }),
  set: (key: string, value: string) => sendCommand<{ done: boolean }>('settings.set', { key, value }),
  reset: () => sendCommand<Record<string, string>>('settings.reset', {}),
  getMlStatus: () => sendCommand<MLStatus>('settings.get_ml_status', {}),
}
