export interface IndexScanParams {
  sessionId: string
  confirmed?: boolean
}

export interface IndexScanResult {
  sessionId: string
  discovered: number
  added: number
  skipped: number
  missing: number
  failed: string[]
}
