import type { IpcMainInvokeEvent } from 'electron'
import type { CommandRegistry } from './registry'
import { ok, err, validateString, wrapHandler } from './helpers'
import type { WritebackOptions, WritebackItem, GroupData } from '@gather/shared'
import { SimilarityService } from '../services/similarity/similarity.service'
import { SettingsService } from '../services/settings'
import { getServices } from '../bootstrap'

function getPhotoPath(item: WritebackItem): string {
  return item.photoPath || (item.xmpPath ? item.xmpPath.replace(/\.xmp$/i, '') : '')
}


export function registerSimilarityHandlers(registry: CommandRegistry): void {
  const { similarityService, writebackService } = getServices()
  const settings = SettingsService.getInstance()
  registry.register(
    'sim.analyze',
    wrapHandler(async (params, event) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const threshold =
        typeof params.threshold === 'number' ? params.threshold : undefined
      const minGroupSize =
        typeof params.minGroupSize === 'number' ? params.minGroupSize : undefined
      const onProgress = event
        ? (current: number, total: number, message: string) => {
            event.sender.send('gather:event', 'progress', { sessionId, current, total, message })
          }
        : undefined
      await similarityService.analyze(sessionId, { threshold, minGroupSize, onProgress })
      return ok(true)
    }),
  )

  registry.register(
    'sim.cancel_analysis',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      await similarityService.cancel(sessionId)
      return ok(true)
    }),
  )

  registry.register(
    'sim.result',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const result = similarityService.getResult(sessionId)
      return ok(result)
    }),
  )

  registry.register(
    'sim.recluster',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const threshold =
        typeof params.threshold === 'number' ? params.threshold : settings.getNumber('default_threshold', 10)
      const minGroupSize =
        typeof params.minGroupSize === 'number' ? params.minGroupSize : settings.getNumber('default_min_group_size', 2)
      const result = await similarityService.recluster(
        sessionId,
        threshold,
        minGroupSize,
      )
      return ok(result)
    }),
  )

  registry.register(
    'sim.preview_writeback',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      const groupIds = (params.groupIds as Array<number | string>) ?? []
      const options = (params.options ?? {}) as WritebackOptions
      const preview = await writebackService.preview(sessionId, 'similarity', options)
      if (groupIds.length > 0) {
        const result = similarityService.getResult(sessionId)
        if (result) {
          const groupIdSet = new Set(groupIds.map(id => typeof id === 'string' ? parseInt(id, 10) : id))
          const groupPaths = new Set<string>()
          for (const group of result.groups) {
            if (groupIdSet.has(group.id)) {
              for (const img of group.images) {
                groupPaths.add(img.path)
              }
            }
          }
          preview.items = preview.items.filter(item => groupPaths.has(getPhotoPath(item)))
          preview.totalCount = preview.items.length
          preview.affectedPhotos = new Set(preview.items.map(item => item.photoId)).size
        }
      }
      return ok(preview)
    }),
  )

  registry.register(
    'sim.writeback',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Writeback requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      const options = (params.options ?? {}) as WritebackOptions
      const items =
        Array.isArray(params.items) && params.items.length > 0
          ? (params.items as WritebackItem[])
          : null
      let writebackItems: WritebackItem[]
      if (items) {
        writebackItems = items
      } else if (Array.isArray(params.groups) && params.groups.length > 0) {
        const groups = params.groups as GroupData[]
        const groupPaths = new Set<string>()
        for (const group of groups) {
          for (const img of group.images) {
            groupPaths.add(img.path)
          }
        }
        const preview = await writebackService.preview(sessionId, 'similarity', options)
        writebackItems = preview.items.filter(item => groupPaths.has(getPhotoPath(item)))
      } else if (Array.isArray(params.groupIds) && params.groupIds.length > 0) {
        const groupIds = params.groupIds as Array<number | string>
        const preview = await writebackService.preview(sessionId, 'similarity', options)
        const result = similarityService.getResult(sessionId)
        if (result) {
          const groupIdSet = new Set(groupIds.map(id => typeof id === 'string' ? parseInt(id, 10) : id))
          const groupPaths = new Set<string>()
          for (const group of result.groups) {
            if (groupIdSet.has(group.id)) {
              for (const img of group.images) {
                groupPaths.add(img.path)
              }
            }
          }
          writebackItems = preview.items.filter(item => groupPaths.has(getPhotoPath(item)))
        } else {
          throw new Error('No similarity result found')
        }
      } else {
        throw new Error('Missing items, groups, or groupIds')
      }
      return ok(await writebackService.execute(sessionId, 'similarity', writebackItems))
    }),
  )

  registry.register(
    'sim.writeback_items',
    wrapHandler(async (params) => {
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await writebackService.preview(sessionId, 'similarity', {} as WritebackOptions))
    }),
  )

  registry.register(
    'sim.retry_failed_writeback',
    wrapHandler(async (params) => {
      if (params.confirmed !== true) {
        throw new Error('Retry failed writeback requires explicit confirmation')
      }
      const sessionId = validateString(params.sessionId, 'sessionId')
      return ok(await writebackService.retryFailed(sessionId, 'similarity'))
    }),
  )
}
