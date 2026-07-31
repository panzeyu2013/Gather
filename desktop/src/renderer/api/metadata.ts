import { sendCommand } from './client'
import type {
  MetadataTags,
  BatchMetadataResult,
  MetadataConflict,
  MetadataConflictChoice,
  MetadataField,
  MetadataOrphan,
  MetadataSyncSummary,
} from '@gather/shared'

export const metadataApi = {
  get: (photoIds: string[]) =>
    sendCommand<Record<string, MetadataTags>>('metadata.get', { photoIds }),

  set: (photoId: string, tags: Partial<MetadataTags>) =>
    sendCommand<MetadataTags>('metadata.set', { photoId, tags, confirmed: true }),

  batchSet: (updates: { photoId: string; tags: Partial<MetadataTags> }[]) =>
    sendCommand<BatchMetadataResult>('metadata.batch_set', { updates, confirmed: true }),

  conflicts: (sessionId: string) =>
    sendCommand<MetadataConflict[]>('metadata.conflicts', { sessionId }),

  resolveConflict: (
    sessionId: string,
    xmpPath: string,
    choices: Partial<Record<MetadataField, MetadataConflictChoice>>,
  ) => sendCommand<MetadataSyncSummary>('metadata.resolve_conflict', {
    sessionId,
    xmpPath,
    choices,
    confirmed: true,
  }),

  orphans: () => sendCommand<MetadataOrphan[]>('metadata.orphans', {}),

  resolveOrphan: (xmpPath: string, action: 'keep' | 'restore' | 'retry') =>
    sendCommand<MetadataOrphan[]>('metadata.resolve_orphan', {
      xmpPath,
      action,
      confirmed: true,
    }),
}
