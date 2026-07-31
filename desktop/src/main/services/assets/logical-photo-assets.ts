import type { PhotoRow } from '../../db/repositories/photo.repo'

const RAW_EXTENSIONS = new Set([
  '.nef', '.nrw', '.arw', '.cr2', '.cr3', '.dng', '.raf', '.orf',
  '.rw2', '.pef', '.srw', '.srf', '.x3f', '.3fr', '.fff', '.mef',
  '.mos', '.iiq', '.eip', '.erf', '.kdc', '.mrw',
])

function extension(filename: string): string {
  const index = filename.lastIndexOf('.')
  return index >= 0 ? filename.slice(index).toLowerCase() : ''
}

/**
 * Analysis and browsing operate on logical Photo Assets, not every physical
 * RAW/JPEG variant. Preserve import order and prefer the RAW member.
 */
export function collapsePhotoAssets(photos: PhotoRow[]): PhotoRow[] {
  const groups = new Map<string, PhotoRow[]>()
  for (const photo of photos) {
    const key = photo.asset_id ?? `photo:${photo.id}`
    const group = groups.get(key) ?? []
    group.push(photo)
    groups.set(key, group)
  }
  return [...groups.values()].map(variants =>
    variants.find(photo => RAW_EXTENSIONS.has(extension(photo.filename)))
      ?? variants[0],
  )
}
