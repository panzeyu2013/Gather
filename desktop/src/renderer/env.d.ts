import type { GatherAPI } from '../preload/index'

declare global {
  interface Window {
    gather: GatherAPI
  }
}
