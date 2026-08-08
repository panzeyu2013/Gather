export function parseKeywords(raw: string): string[] {
  if (!raw || raw === '[]') return []
  try {
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

export async function batchAsync<T, R>(
  items: T[],
  fn: (item: T) => Promise<R>,
  concurrency: number = 10,
): Promise<R[]> {
  // Sliding window: a fixed set of resident runners pulls from a shared index
  // cursor, so a slow item no longer stalls the whole batch (the old windowed
  // Promise.all waited for the slowest item of every batch). Result order,
  // error semantics and the per-item fn invocation count are unchanged:
  // - results are collected by input index, so the returned array is ordered;
  // - the first rejection rejects the whole call and stops further
  //   scheduling, while items already dispatched keep running to completion
  //   (same as Promise.all over a window);
  // - every item's fn still runs exactly once.
  const limit = Math.max(1, Math.floor(concurrency) || 1)
  const results: R[] = new Array(items.length)
  let nextIndex = 0
  let inFlight = 0
  let failure: unknown
  let settled = false

  let settle!: (value: R[]) => void
  let reject!: (reason: unknown) => void
  const outcome = new Promise<R[]>((resolve, rejectPromise) => {
    settle = resolve
    reject = rejectPromise
  })

  const maybeFinish = (): void => {
    if (settled) return
    if (failure !== undefined) {
      settled = true
      reject(failure)
    } else if (inFlight === 0 && nextIndex >= items.length) {
      settled = true
      settle(results)
    }
  }

  const worker = async (): Promise<void> => {
    while (!settled) {
      const index = nextIndex
      if (index >= items.length) return
      nextIndex = index + 1
      inFlight++
      try {
        results[index] = await fn(items[index])
      } catch (error) {
        if (failure === undefined) failure = error
        inFlight--
        maybeFinish()
        return
      }
      inFlight--
      maybeFinish()
    }
  }

  const workerCount = Math.min(limit, items.length)
  for (let i = 0; i < workerCount; i++) {
    void worker()
  }
  maybeFinish()
  return outcome
}
