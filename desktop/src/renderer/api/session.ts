import { sendCommand } from './client'
import type { SessionData, AddPhotoResult } from '@gather/shared'

export const sessionApi = {
  list: () => sendCommand<SessionData[]>('session.list'),
  get: (id: string) => sendCommand<SessionData>('session.get', { sessionId: id }),
  create: (name: string, source: string) =>
    sendCommand<SessionData>('session.create', { name, source }),
  delete: (id: string) =>
    sendCommand<boolean>('session.delete', { sessionId: id, confirmed: true }),
  addPhotos: (sessionId: string, paths: string[]) =>
    sendCommand<AddPhotoResult>('session.add_photos', { sessionId, filepaths: paths }),
  update: (sessionId: string, name: string) =>
    sendCommand<SessionData>('session.update', { sessionId, name }),
}
