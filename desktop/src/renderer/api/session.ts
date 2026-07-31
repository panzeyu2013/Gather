import { sendCommand } from './client'
import type { SessionData, AddPhotoResult, PhotoData } from '@gather/shared'

type SessionCreateResult = SessionData & Pick<AddPhotoResult, 'added' | 'skipped' | 'failedFiles'>

export const sessionApi = {
  list: () => sendCommand<SessionData[]>('session.list'),
  get: (id: string) => sendCommand<SessionData>('session.get', { sessionId: id }),
  create: (name: string, source: string, filepaths?: string[], sourcePath?: string) =>
    sendCommand<SessionCreateResult>('session.create', { name, source, filepaths, sourcePath }),
  delete: (id: string) =>
    sendCommand<boolean>('session.delete', { sessionId: id, confirmed: true }),
  deleteMany: (ids: string[]) =>
    sendCommand<{ deletedCount: number }>('session.delete_many', { sessionIds: ids, confirmed: true }),
  addPhotos: (sessionId: string, paths: string[]) =>
    sendCommand<AddPhotoResult>('session.add_photos', { sessionId, filepaths: paths }),
  update: (sessionId: string, name: string) =>
    sendCommand<SessionData>('session.update', { sessionId, name }),
  getPhotos: (sessionId: string, expandVariants = false) =>
    sendCommand<PhotoData[]>('photo.list', { sessionId, expandVariants }),
}
