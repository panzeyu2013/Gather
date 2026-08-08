import { sendCommand } from './client'
import type { SessionData, AddPhotoResult, PhotoData } from '@gather/shared'

type SessionCreateResult = SessionData & Pick<AddPhotoResult, 'added' | 'skipped' | 'failedFiles'>

export const sessionApi = {
  list: () => sendCommand<SessionData[]>('session.list'),
  get: (id: string) => sendCommand<SessionData>('session.get', { sessionId: id }),
  create: (
    name: string,
    source: string,
    filepaths?: string[],
    sourcePath?: string,
    truncatedImport?: boolean,
  ) =>
    sendCommand<SessionCreateResult>('session.create', { name, source, filepaths, sourcePath, truncatedImport }),
  /** One-hop local import: only the source path crosses IPC; the main process
   * creates the session and enqueues the `metadata.scan` index job. */
  createFromDirectory: (name: string | undefined, sourcePath: string) =>
    sendCommand<SessionData>('session.create_from_directory', { name, sourcePath }),
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
  getPhotosPage: (
    sessionId: string,
    options: { afterFirstRowid?: number; limit?: number; expandVariants?: boolean } = {},
  ) =>
    sendCommand<{ rows: PhotoData[]; cursor: number | null }>('photo.list_page', {
      sessionId,
      afterFirstRowid: options.afterFirstRowid,
      limit: options.limit,
      expandVariants: options.expandVariants,
    }),
}
