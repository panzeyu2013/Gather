import { sendCommand } from './client'

export interface ImagePreviewResult {
  buffer: string
  width: number
  height: number
  format: string
}

export const imageApi = {
  getThumbnail: (path: string, size = 320) =>
    sendCommand<ImagePreviewResult>('image.get_thumbnail', { path, size }),
  getPreview: (path: string, maxDimension = 1920) =>
    sendCommand<ImagePreviewResult>('image.get_preview', { path, maxDimension }),
  prioritizeThumbnail: (path: string, size = 320) =>
    sendCommand<void>('image.prioritize_thumbnail', { path, size }),
  preloadThumbnails: (paths: string[], size = 320) =>
    sendCommand<void>('image.preload_thumbnails', { paths, size }),
  getDimensions: (paths: string[]) =>
    sendCommand<Record<string, { width: number; height: number }>>('image.get_dimensions', { paths }),
}
