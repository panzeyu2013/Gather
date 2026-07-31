import type {
  MetadataMutationResult,
  MetadataMutationSource,
  MetadataPatch,
} from '@gather/shared'
import { injectable, inject } from '../../di/container'
import { DI_TOKENS } from '../../di/container'
import { MetadataOutboxRepository } from '../../db/repositories/metadata-outbox.repo'
import { MetadataWriterRouter } from '../xmp/metadata-writer-router'
import { MetadataSyncCoordinator } from './metadata-sync-coordinator'
import {
  normalizeKeywords,
  validateMetadataPatch,
} from './metadata-contract'
import { PhotoAssetResolver } from '../assets/photo-asset-resolver'

function parsePendingKeywords(value: string | undefined): string[] | null {
  if (!value) return null
  try {
    const parsed = JSON.parse(value) as { keywords?: unknown }
    return Array.isArray(parsed.keywords) ? normalizeKeywords(parsed.keywords) : null
  } catch {
    return null
  }
}

@injectable()
export class MetadataMutationService {
  private mutationQueues = new Map<string, Promise<void>>()

  constructor(
    @inject(DI_TOKENS.METADATA_OUTBOX_REPO) private outboxRepo: MetadataOutboxRepository,
    @inject(DI_TOKENS.WRITER_ROUTER) private writerRouter: MetadataWriterRouter,
    @inject(DI_TOKENS.METADATA_SYNC_COORDINATOR) private sync: MetadataSyncCoordinator,
    @inject(DI_TOKENS.PHOTO_ASSET_RESOLVER) private assetResolver: PhotoAssetResolver,
  ) {}

  queuePhotoValues(
    sessionId: string,
    photoId: string,
    values: Record<string, unknown>,
    source: MetadataMutationSource,
    schedule = true,
  ): MetadataMutationResult {
    const resolved = this.assetResolver.resolve(sessionId, photoId)
    const dirtyFields = Object.keys(values).filter(field => ['rating', 'label', 'keywords'].includes(field)) as Array<'rating' | 'label' | 'keywords'>
    if (dirtyFields.length === 0) throw new Error('Metadata mutation has no supported fields')
    const row = this.outboxRepo.mergePatch(
      resolved.xmpPath,
      sessionId,
      resolved.filepath,
      { ...values, source },
      dirtyFields,
    )
    if (schedule) this.sync.schedule(row.xmp_path)
    return {
      photoId,
      xmpPath: row.xmp_path,
      dirtyFields,
      revision: row.revision,
      status: row.status,
    }
  }

  async queueMutation(
    sessionId: string,
    photoId: string,
    patch: MetadataPatch,
    source: MetadataMutationSource,
  ): Promise<MetadataMutationResult> {
    const normalized = validateMetadataPatch(patch)
    const resolved = this.assetResolver.resolve(sessionId, photoId)
    const xmpPath = resolved.xmpPath
    const previous = this.mutationQueues.get(xmpPath) ?? Promise.resolve()
    let release!: () => void
    const currentTurn = new Promise<void>(resolve => { release = resolve })
    const queued = previous.then(() => currentTurn)
    this.mutationQueues.set(xmpPath, queued)
    await previous
    try {
      const writer = this.writerRouter.selectSidecar()
      const current = await writer.readAttributes(resolved.filepath)
      const pending = parsePendingKeywords(this.outboxRepo.get(xmpPath)?.patch_json)
      const existingKeywords = pending ?? normalizeKeywords(current.keywords ?? [])
      const values: Record<string, unknown> = {}
      if (normalized.rating) values.rating = normalized.rating.value
      if (normalized.label) values.label = normalized.label.value === 'None' ? '' : normalized.label.value
      if (normalized.keywords) {
        const incoming = normalized.keywords.values
        if (normalized.keywords.op === 'append') values.keywords = normalizeKeywords([...existingKeywords, ...incoming])
        else if (normalized.keywords.op === 'remove') {
          const remove = new Set(incoming)
          values.keywords = existingKeywords.filter(keyword => !remove.has(keyword))
        } else values.keywords = incoming
      }
      return this.queuePhotoValues(sessionId, photoId, values, source)
    } finally {
      release()
      if (this.mutationQueues.get(xmpPath) === queued) {
        this.mutationQueues.delete(xmpPath)
      }
    }
  }
}
