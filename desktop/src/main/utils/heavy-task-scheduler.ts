import os from 'os'

interface PendingTask {
  priority: number
  order: number
  start: () => void
}

/**
 * Process-wide admission control for CPU-heavy native work. Individual
 * services still keep their own narrower limits, while this scheduler prevents
 * Sharp, ONNX and export jobs from independently saturating every core.
 */
class HeavyTaskScheduler {
  private active = 0
  private order = 0
  private pending: PendingTask[] = []
  private readonly limit = Math.max(2, Math.min(6, os.cpus().length - 1))

  async run<T>(task: () => Promise<T>, priority = 1): Promise<T> {
    if (this.active >= this.limit) {
      await new Promise<void>((resolve) => {
        this.pending.push({
          priority,
          order: this.order++,
          start: resolve,
        })
        this.pending.sort(
          (a, b) => a.priority - b.priority || a.order - b.order,
        )
      })
    }

    this.active++
    try {
      return await task()
    } finally {
      this.active--
      this.pending.shift()?.start()
    }
  }
}

export const heavyTaskScheduler = new HeavyTaskScheduler()
