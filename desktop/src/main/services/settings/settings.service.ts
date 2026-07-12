import { SettingsRepository } from '../../db/repositories/settings.repo'
import { MODEL_CONFIG } from '../face-kw/model-config'

export class SettingsService {
  private cache = new Map<string, string>()
  private repo = new SettingsRepository()

  constructor() {
    this.loadCache()
  }

  private loadCache(): void {
    const all = this.repo.getAll()
    for (const { key, value } of all) {
      this.cache.set(key, value)
    }
  }

  get(key: string, defaultValue?: string): string {
    return this.cache.get(key) ?? defaultValue ?? ''
  }

  getNumber(key: string, defaultValue: number): number {
    const val = this.cache.get(key)
    if (val === undefined) return defaultValue
    const num = parseFloat(val)
    return isNaN(num) ? defaultValue : num
  }

  set(key: string, value: string): void {
    this.repo.upsert(key, value)
    this.cache.set(key, value)
  }

  getAll(): Record<string, string> {
    const defaults = getDefaults()
    const result: Record<string, string> = {}
    for (const [key, value] of Object.entries(defaults)) {
      result[key] = String(value)
    }
    for (const [key, value] of this.cache) {
      result[key] = value
    }
    return result
  }

  reset(): void {
    const defaults = getDefaults()
    const entries = Object.entries(defaults).map(([key, value]) => ({ key, value: String(value) }))
    this.repo.batchUpsert(entries)
    for (const [key, value] of Object.entries(defaults)) {
      this.cache.set(key, String(value))
    }
  }

  private static instance: SettingsService | null = null
  static getInstance(): SettingsService {
    if (!SettingsService.instance) {
      SettingsService.instance = new SettingsService()
    }
    return SettingsService.instance
  }
}

export function getDefaults(): Record<string, string | number> {
  return {
    detector_model_path: 'models/face_detector.onnx',
    encoder_model_path: 'models/face_encoder.onnx',
    onnx_provider: 'auto',
    detect_confidence: 0.5,
    detect_input_size: 640,
    encoder_input_size: 112,
    embedding_dim: 512,

    default_eps: 0.6,
    default_min_samples: 2,

    nms_threshold: 0.4,
    max_detections: 100,
    onnx_threads: 4,

    default_threshold: 10,
    default_min_group_size: 2,

    model_download_url: '',

    thumbnail_size: 320,
    thumbnail_quality: 80,
    face_thumbnail_size: 80,
    face_thumbnail_quality: 70,

    memory_cache_size: 200,
    disk_cache_dir: '',
    disk_cache_max_size_gb: 1,
    disk_cache_eviction_policy: 'lru',
    thumbnail_concurrency: 0,

    db_cache_size_mb: 64,
    db_synchronous: 'normal',

    hash_chunk_size: 8,

    c1_timeout_ms: 15000,
    c1_retries: 3,
    c1_reload_delay_ms: 500,

    poll_max_retries_sim: 300,
    poll_max_retries_fkw: 240,
    poll_interval_sim_ms: 1000,
    poll_interval_fkw_ms: 3000,
  }
}
