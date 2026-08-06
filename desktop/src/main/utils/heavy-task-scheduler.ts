import os from 'os'

interface PendingTask {
  priority: number
  order: number
  weight: number
  start: () => void
}

/**
 * Process-wide admission control for CPU-heavy native work, accounted in
 * weight units: a running task claims `weight` units of the shared budget,
 * and queued tasks are admitted in (priority, order) order whenever the
 * budget has room for their weight. Individual services still keep their own
 * narrower limits, while this scheduler prevents Sharp, ONNX and export jobs
 * from independently saturating every core.
 */
export class HeavyTaskScheduler {
  private activeWeight = 0
  private order = 0
  private pending: PendingTask[] = []
  private readonly budget: number

  constructor(budget?: number) {
    this.budget = Math.max(1, budget ?? Math.max(2, Math.min(6, os.cpus().length - 1)))
  }

  async run<T>(task: () => Promise<T>, priority = 1, weight = 1): Promise<T> {
    const units = Math.max(1, Math.floor(weight))
    const queued = this.activeWeight + units > this.budget
    if (queued) {
      await new Promise<void>((resolve) => {
        this.pending.push({
          priority,
          order: this.order++,
          weight: units,
          start: resolve,
        })
        this.pending.sort(
          (a, b) => a.priority - b.priority || a.order - b.order,
        )
      })
    }
    // When queued, releasePending() already counted our units while waking us.
    if (!queued) this.activeWeight += units
    try {
      return await task()
    } finally {
      this.activeWeight -= units
      this.releasePending()
    }
  }

  private releasePending(): void {
    if (this.pending.length === 0) return
    const queued = this.pending
    this.pending = []
    let available = this.budget - this.activeWeight
    for (const task of queued) {
      if (task.weight <= available) {
        available -= task.weight
        this.activeWeight += task.weight
        task.start()
      } else {
        this.pending.push(task)
      }
    }
  }
}

export const heavyTaskScheduler = new HeavyTaskScheduler()
