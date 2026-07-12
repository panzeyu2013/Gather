import { sendCommand } from './client'
import type { MetadataTags, BatchMetadataResult } from '@gather/shared'

export const metadataApi = {
  get: (photoIds: string[]) =>
    sendCommand<Record<string, MetadataTags>>('metadata.get', { photoIds }),

  set: (photoId: string, tags: Partial<MetadataTags>) =>
    sendCommand<MetadataTags>('metadata.set', { photoId, tags, confirmed: true }),

  batchSet: (updates: { photoId: string; tags: Partial<MetadataTags> }[]) =>
    sendCommand<BatchMetadataResult>('metadata.batch_set', { updates, confirmed: true }),
}
