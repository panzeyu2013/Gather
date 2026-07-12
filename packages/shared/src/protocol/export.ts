// packages/shared/src/protocol/export.ts

export interface ExportPreviewParams { sessionId: string; options: ExportOptions }
export interface ExportExecuteParams { sessionId: string; options: ExportOptions; confirmed: boolean }
export interface ExportCancelParams { }
export interface ExportReportParams { sessionId: string; reportType: string; format?: string }

export interface ExportOptions {
  scope: 'selected' | 'filtered' | 'session'
  format: 'original' | 'jpeg' | 'tiff'
  quality?: number
  maxDimension?: number
  tiffCompression?: 'none' | 'lzw' | 'deflate'
  watermark?: {
    type: 'text' | 'image'
    content: string
    position: 'center' | 'bottom-right' | 'bottom-left'
    opacity: number
    fontSize?: number
  }
  naming: {
    pattern: string
    counterStart?: number
    dateFormat?: string
  }
  includeXmp: boolean
  destination: string
  skipRemoved: boolean
}

export interface ExportPreview {
  totalFiles: number
  totalSizeBytes: number
  freeSpaceBytes: number
  files: { photoId: string; filename: string; fileSize: number }[]
}

export interface ExportResult {
  totalFiles: number
  exported: number
  failed: number
  skipped: number
  errors: string[]
}

export interface ExportProgressEvent {
  current: number
  total: number
  fileName: string
  bytesWritten: number
  status: 'pending' | 'processing' | 'done' | 'skipped' | 'error'
  errorMessage?: string
}

export interface ReportData {
  path: string
  content: string
  format: 'csv' | 'md'
}
