import type { CommandRegistry } from './registry'
import { ok, validateString, wrapHandler } from './helpers'
import type { AssetRepository } from '../db/repositories/asset.repo'

export function registerAssetHandlers(
  registry: CommandRegistry,
  assets: AssetRepository,
): void {
  registry.register('assets.candidates', wrapHandler(async params => {
    const sessionId = params.sessionId === undefined
      ? undefined
      : validateString(params.sessionId, 'sessionId')
    return ok(assets.listCandidates(sessionId))
  }))
  registry.register('assets.accept_candidate', wrapHandler(async params => {
    if (params.confirmed !== true) throw new Error('Accepting an Asset link requires confirmation')
    assets.acceptCandidate(validateString(params.candidateId, 'candidateId'))
    return ok(true)
  }))
  registry.register('assets.reject_candidate', wrapHandler(async params => {
    if (params.confirmed !== true) throw new Error('Rejecting an Asset link requires confirmation')
    assets.rejectCandidate(validateString(params.candidateId, 'candidateId'))
    return ok(true)
  }))
  registry.register('assets.volumes', wrapHandler(async () => {
    return ok(assets.listVolumes())
  }))
  registry.register('assets.relink_root', wrapHandler(async params => {
    if (params.confirmed !== true) throw new Error('Relinking an Asset root requires confirmation')
    return ok(assets.relinkRoot(
      validateString(params.oldRoot, 'oldRoot'),
      validateString(params.newRoot, 'newRoot'),
    ))
  }))
}
