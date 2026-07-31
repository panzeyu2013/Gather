import { sendCommand } from './client'
import type { AssetLinkCandidateData, AssetVolumeData } from '@gather/shared'

export const assetApi = {
  candidates: () =>
    sendCommand<AssetLinkCandidateData[]>('assets.candidates', {}),
  acceptCandidate: (candidateId: string) =>
    sendCommand<boolean>('assets.accept_candidate', { candidateId, confirmed: true }),
  rejectCandidate: (candidateId: string) =>
    sendCommand<boolean>('assets.reject_candidate', { candidateId, confirmed: true }),
  volumes: () => sendCommand<AssetVolumeData[]>('assets.volumes', {}),
  relinkRoot: (oldRoot: string, newRoot: string) =>
    sendCommand<number>('assets.relink_root', { oldRoot, newRoot, confirmed: true }),
}
