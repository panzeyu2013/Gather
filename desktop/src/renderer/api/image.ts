import { sendCommand } from './client'

function imageUrl(kind: 'thumbnail' | 'preview', path: string, size: number): string {
  const params = new URLSearchParams({ path, size: String(size) })
  return `gather-image://${kind}?${params.toString()}`
}

export const imageApi = {
  thumbnailUrl: (path: string, size = 1024) => imageUrl('thumbnail', path, size),
  previewUrl: (path: string, maxDimension = 2048) => imageUrl('preview', path, maxDimension),
  prioritizeThumbnail: (path: string, size = 1024) =>
    sendCommand<void>('image.prioritize_thumbnail', { path, size }),
  preloadThumbnails: (paths: string[], size = 1024) =>
    sendCommand<void>('image.preload_thumbnails', { paths, size }),
  preloadPreviews: (paths: string[], maxDimension = 2048) =>
    sendCommand<void>('image.preload_previews', { paths, maxDimension }),
  getDimensions: (paths: string[]) =>
    sendCommand<Record<string, { width: number; height: number }>>('image.get_dimensions', { paths }),
}
