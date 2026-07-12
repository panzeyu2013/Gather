import { sendCommand } from './client'
import type { PersonData, PersonDetailData, PersonPhotoItem } from '@gather/shared'

export const personApi = {
  list: () =>
    sendCommand<PersonData[]>('person.list', {}),

  get: (personId: string) =>
    sendCommand<PersonDetailData>('person.get', { personId }),

  create: (name: string, keywords?: string[]) =>
    sendCommand<{ id: string }>('person.create', { name, keywords }),

  update: (personId: string, fields: { name?: string; keywords?: string[]; notes?: string; matchThreshold?: number }) =>
    sendCommand<{ done: boolean }>('person.update', { personId, ...fields }),

  delete: (personId: string) =>
    sendCommand<{ done: boolean }>('person.delete', { personId, confirmed: true }),

  merge: (sourceId: string, targetId: string) =>
    sendCommand<{ done: boolean }>('person.merge', { sourceId, targetId, confirmed: true }),

  removePhoto: (personId: string, photoId: string) =>
    sendCommand<{ done: boolean }>('person.remove_photo', { personId, photoId, confirmed: true }),

  searchPhotos: (personId: string, opts?: { sessionIds?: string[]; limit?: number; offset?: number }) =>
    sendCommand<{ photos: PersonPhotoItem[]; total: number }>('person.search_photos', { personId, ...opts }),
}
