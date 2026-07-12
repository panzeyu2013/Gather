import { sendCommand } from './client'
import type { FilterGroup, FilterSuggestion, GlobalPhotoResult, PhotoData, SmartAlbumData, SmartAlbumDetailData } from '@gather/shared'

export const filterApi = {
  photos: (sessionId: string, criteria: FilterGroup, sortBy?: string, sortOrder?: string) =>
    sendCommand<PhotoData[]>('filter.photos', { sessionId, criteria, sortBy, sortOrder }),

  photosGlobal: (criteria: FilterGroup) =>
    sendCommand<GlobalPhotoResult[]>('filter.photos_global', { criteria }),

  suggest: (sessionId: string, keyword: string) =>
    sendCommand<FilterSuggestion[]>('filter.suggest', { sessionId, keyword }),
}

export const albumApi = {
  list: () =>
    sendCommand<SmartAlbumData[]>('album.list', {}),

  get: (albumId: string) =>
    sendCommand<SmartAlbumDetailData>('album.get', { albumId }),

  create: (params: { name: string; criteria: FilterGroup; sortBy?: string; sortOrder?: string }) =>
    sendCommand<SmartAlbumDetailData>('album.create', params),

  update: (albumId: string, params: { name?: string; criteria?: FilterGroup; sortBy?: string; sortOrder?: string }) =>
    sendCommand<{ done: boolean }>('album.update', { albumId, ...params }),

  delete: (albumId: string) =>
    sendCommand<{ done: boolean }>('album.delete', { albumId, confirmed: true }),

  getPhotos: (albumId: string, limit?: number, offset?: number) =>
    sendCommand<{ photos: PhotoData[]; total: number }>('album.get_photos', { albumId, limit, offset }),
}
