import * as os from 'os'
import { ImageService, TieredThumbnailCache } from './image.service'
import { SettingsService } from '../settings'

interface QueueJob {
  path: string
  size: number
}

export class ThumbnailQueue {
  private pending: QueueJob[] = []
  private inProgress = new Set<string>()
  private active = 0
  private processing = false

  private cacheKey(path: string, size: number): string {
    return `${path}::${size}`
  }

  private get maxConcurrency(): number {
    const configured = SettingsService.getInstance().getNumber('thumbnail_concurrency', 0)
    if (configured > 0) return configured
    return Math.max(2, os.cpus().length - 1)
  }

  enqueue(paths: string[], size: number): void {
    for (const p of paths) {
      const key = this.cacheKey(p, size)
      if (this.inProgress.has(key)) continue
      if (this.pending.some((j) => j.path === p && j.size === size)) continue
      this.pending.push({ path: p, size })
    }
    this.process()
  }

  enqueuePriority(path: string, size: number): void {
    const key = this.cacheKey(path, size)
    if (this.inProgress.has(key)) return
    const idx = this.pending.findIndex((j) => j.path === path && j.size === size)
    if (idx >= 0) {
      this.pending.splice(idx, 1)
    }
    this.pending.unshift({ path, size })
    this.process()
  }

  private async process(): Promise<void> {
    if (this.processing) return
    this.processing = true

    while (this.active < this.maxConcurrency && this.pending.length > 0) {
      const job = this.pending.shift()!
      const key = this.cacheKey(job.path, job.size)
      this.inProgress.add(key)
      this.active++
      ImageService.getInstance(new TieredThumbnailCache())
        .getThumbnail(job.path, job.size)
        .catch(() => {})
        .finally(() => {
          this.inProgress.delete(key)
          this.active--
          this.processing = false
          this.process()
        })
    }

    this.processing = false
  }

  private static instance: ThumbnailQueue | null = null
  static getInstance(): ThumbnailQueue {
    if (!ThumbnailQueue.instance) {
      ThumbnailQueue.instance = new ThumbnailQueue()
    }
    return ThumbnailQueue.instance
  }
}
