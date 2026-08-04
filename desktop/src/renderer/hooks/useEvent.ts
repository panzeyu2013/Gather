import { useEffect, useRef } from 'react'
import type { Event } from '@gather/shared'

type EventType = Event['type']

/**
 * Subscribes to a main-process push event with guaranteed cleanup on unmount,
 * preventing listener leaks on the shared `gather:event` channel. The latest
 * callback is used, so it can be recreated on every render without resubscribing.
 */
export function useEvent(
  type: EventType,
  callback: (data: unknown) => void,
  enabled = true,
): void {
  const callbackRef = useRef(callback)
  callbackRef.current = callback

  useEffect(() => {
    if (!enabled) return undefined
    return window.gather.onEvent(type, (data) => callbackRef.current(data))
  }, [type, enabled])
}
