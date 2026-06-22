// src/renderer/utils/poll.ts
// 通用轮询工具

export function createPollLoop<T>(
  fetchFn: () => Promise<T>,
  isDonePredicate: (data: T) => boolean,
  maxRetries: number,
  intervalMs: number,
  onError?: (err: unknown) => void,
  onTimeout?: () => void,
): { start: (delayMs?: number) => void; stop: () => void } {
  let pollTimer: ReturnType<typeof setTimeout> | null = null
  let attempts = 0
  let inFlight = false
  let stopped = false

  function stop(): void {
    stopped = true
    if (pollTimer) { clearTimeout(pollTimer); pollTimer = null }
  }

  function check(): void {
    if (inFlight || stopped) return
    inFlight = true
    fetchFn().then(data => {
      inFlight = false
      if (stopped) return
      if (isDonePredicate(data)) {
        stop()
        return
      }
      if (++attempts > maxRetries) {
        stop()
        onTimeout?.()
        return
      }
      pollTimer = setTimeout(check, intervalMs)
    }).catch((err: unknown) => {
      inFlight = false
      if (stopped) return
      onError?.(err)
      if (++attempts > maxRetries) {
        stop()
        onTimeout?.()
        return
      }
      pollTimer = setTimeout(check, intervalMs)
    })
  }

  function start(delayMs?: number): void {
    stop()
    attempts = 0
    stopped = false
    pollTimer = setTimeout(check, delayMs ?? intervalMs)
  }

  return { start, stop }
}
