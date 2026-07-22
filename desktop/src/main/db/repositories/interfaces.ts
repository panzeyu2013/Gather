import type { PhotoRow } from './photo.repo'
import type { SessionRow } from './session.repo'
import type { FaceObservationInput, FaceObservationRow, FaceClusterInput, FaceClusterRow, FaceClusterMemberRow } from './face.repo'
import type { PersonRow, PersonEmbeddingRow, PersonPhotoRow, SaveEmbeddingInput, PersonUpdateFields } from './person.repo'
import type { CullingDecisionRow } from './culling-decision.repo'
import type { SimilarityResultRow } from './similarity-result.repo'
import type { OperationLogRow } from './operation-log.repo'
import type { WritebackItemInput, WritebackItemRow } from './writeback.repo'
import type { MetadataCacheRow, MetadataCacheInput } from './metadata-cache.repo'
import type { SmartAlbumRow, SmartAlbumCreateData, SmartAlbumUpdateData } from './smart-album.repo'

export interface IPhotoRepository {
  getBySession(sessionId: string): PhotoRow[]
  countBySession(sessionId: string): number
  addPhotos(sessionId: string, filepaths: Array<{ filepath: string; width: number; height: number }>, source: string): { added: number; skipped: number }
  deleteBySession(sessionId: string): void
}

export interface ISessionRepository {
  get(id: string): SessionRow | null
  create(name: string, source: string): SessionRow
  delete(id: string): boolean
  deleteMany(ids: string[]): number
  deleteSimilarityDataBySession(sessionId: string): void
  list(): SessionRow[]
  updateName(id: string, name: string): boolean
  updateStatus(id: string, status: string): void
  updatePhotoCount(id: string, count: number): void
  updateAnalysisStatus(id: string, status: string): void
  updateWritebackStatus(id: string, status: string): void
  updateFailedWritebackCount(id: string, count: number): void
}

export interface IFaceRepository {
  saveObservations(sessionId: string, observations: FaceObservationInput[]): number[]
  getObservations(sessionId: string): FaceObservationRow[]
  updateEmbedding(observationId: number, embedding: number[]): void
  deleteObservationsBySession(sessionId: string): void
  updateClusterThumbnail(clusterId: number, thumbnailPath: string): void
  saveClusters(sessionId: string, clusters: FaceClusterInput[]): number[]
  getClusters(sessionId: string, includeMembers?: boolean): FaceClusterRow[]
  updateBinding(clusterId: number, roleName: string, keywords: string[]): void
  deleteBinding(clusterId: number): void
  mergeClusters(sourceId: number, targetId: number): void
  deleteClustersBySession(sessionId: string): void
  removeMemberFromCluster(clusterId: number, photoId: string): void
  getClusterThumbnailPath(clusterId: number): string
  getThumbnailPathsBySession(sessionId: string): string[]
  getFaceThumbDir(): string
}

export interface IPersonRepository {
  list(): PersonRow[]
  listWithCounts(): (PersonRow & { photo_count: number; session_count: number })[]
  get(id: string): PersonRow | undefined
  create(name: string, keywords?: string[]): string
  update(id: string, fields: PersonUpdateFields): void
  updateThumbnail(id: string, base64: string): void
  delete(id: string): void
  merge(sourceId: string, targetId: string): void
  getPhotos(personId: string, sessionIds?: string[], limit?: number, offset?: number): PersonPhotoRow[]
  removePhoto(personId: string, photoId: string): void
  getPersonPhoto(personId: string, photoId: string): PersonPhotoRow | undefined
  addPhoto(personId: string, photoId: string, sessionId: string, faceBbox: number[], confidence: number): void
  saveEmbeddings(embeddings: SaveEmbeddingInput[]): void
  deleteEmbeddingsByObservationIds(observationIds: number[]): void
  getAllEmbeddings(): { person_id: string; embedding: Buffer; face_observation_id: number | null }[]
  getEmbeddingsByPerson(personId: string): PersonEmbeddingRow[]
  deleteEmbeddingsByPerson(personId: string): void
  countEmbeddings(personId: string): number
  countPhotos(personId: string): number
  getSessionCount(personId: string): number
  getThumbnailBase64(personId: string): string
  getPhotosWithDetails(personId: string, sessionIds?: string[], limit?: number, offset?: number): { photos: (PersonPhotoRow & { sessionName: string; filename: string; filepath: string })[]; total: number }
}

export interface ICullingDecisionRepository {
  getDecisions(sessionId: string): { photo_id: string; decision: string }[]
  getDecisionsFull(sessionId: string): CullingDecisionRow[]
  getBySession(sessionId: string): CullingDecisionRow[]
  getDecision(sessionId: string, photoId: string): CullingDecisionRow | undefined
  upsert(sessionId: string, photoId: string, groupId: string, decision: string): void
  getDecisionCounts(sessionId: string): { decision: string; cnt: number }[]
  deleteBySession(sessionId: string): void
  deleteBySessionAndGroup(sessionId: string, groupId: string): void
}

export interface ISimilarityResultRepository {
  getLatest(sessionId: string): SimilarityResultRow | undefined
  insert(sessionId: string, groupsJson: string, statsJson: string, threshold: number, minGroupSize: number): void
}

export interface IOperationLogRepository {
  insert(sessionId: string, operationType: string, params: string, snapshotBefore: string | null, snapshotAfter: string | null, description: string, createdAt: string): void
  list(sessionId: string, limit: number, offset: number): OperationLogRow[]
  getLatestNonUndo(sessionId: string): OperationLogRow | undefined
  getLatestUndo(sessionId: string): OperationLogRow | undefined
  getById(sessionId: string, operationId: number, isUndo: number): OperationLogRow | undefined
  getIsUndoStatus(operationId: number): { is_undo: number } | undefined
  markUndone(operationId: number): void
  markRedone(operationId: number): void
}

export interface IWritebackRepository {
  saveItems(sessionId: string, module: string, items: WritebackItemInput[]): void
  getItems(sessionId: string, module?: string, status?: string): WritebackItemRow[]
  updateStatus(itemId: number, status: string, error?: string): void
  getFailedCount(sessionId: string): number
  deleteItems(sessionId: string): void
  updateBackupPath(itemId: number, path: string): void
}

export interface IMetadataCacheRepository {
  upsert(photoId: string, sessionId: string, data: MetadataCacheInput): void
  get(photoId: string): MetadataCacheRow | null
  getBatch(photoIds: string[]): MetadataCacheRow[]
  deleteBySession(sessionId: string): void
  updateRating(photoId: string, rating: number): void
}

export interface ISmartAlbumRepository {
  list(): SmartAlbumRow[]
  get(id: string): SmartAlbumRow | undefined
  create(data: SmartAlbumCreateData): SmartAlbumRow
  update(id: string, data: SmartAlbumUpdateData): void
  delete(id: string): void
}
