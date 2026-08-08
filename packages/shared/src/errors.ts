export class GatherError extends Error {
  override name = 'GatherError'
}

export class ValidationError extends GatherError {
  override name = 'ValidationError'
}

export class NotFoundError extends GatherError {
  override name = 'NotFoundError'
}

export class DetectionError extends GatherError {
  override name = 'DetectionError'
}

export class EncodingError extends GatherError {
  override name = 'EncodingError'
}

export class ClusteringError extends GatherError {
  override name = 'ClusteringError'
}

export class CancelledError extends GatherError {
  override name = 'CancelledError'
}

export class DatabaseError extends GatherError {
  override name = 'DatabaseError'
}

export class InitializationError extends GatherError {
  override name = 'InitializationError'
}

/**
 * Error codes thrown by the main process (design_improvements.md 4.4.2).
 * The main process never owns user-facing copy: it throws codes, and the
 * renderer maps them to translated strings. A plain `Error` whose `message`
 * is one of these codes is the canonical carrier across IPC.
 */
export const GATHER_ERROR_CODES = [
  'C1_NOT_RUNNING',
  'C1_NO_DOCUMENT',
  'C1_NOT_AUTHORIZED',
  'C1_SCRIPT_FAILED',
  'SCAN_INVALID_DIR',
  'SCAN_READ_FAILED',
  // XMP / metadata sync coordinator + writeback
  'XMP_CONFLICT_RESOLUTION_REQUIRED',
  'XMP_CONFIRM_INCOMPLETE',
  'XMP_CLEANUP_REQUIRES_LOADED',
  'XMP_CONFIRM_REQUIRES_SYNC',
  'XMP_EXTERNALLY_MODIFIED',
  'XMP_BACKUP_MISSING',
  'XMP_CLEANUP_ABORTED_EXTERNAL_EDIT',
  'XMP_EXTERNAL_EDIT_CONFLICT',
  'XMP_RELOAD_NOT_ACKED',
  'XMP_CONFLICT_NOT_FOUND',
  'XMP_CONFLICT_DETAILS_UNAVAILABLE',
  'XMP_CHOICE_MISSING',
  'XMP_CONFLICT_DETAILS_INVALID',
  'XMP_ORPHAN_NOT_FOUND',
  'XMP_ORPHAN_NOT_RETRYABLE',
  'XMP_WRITER_TIMEOUT',
  'WRITEBACK_OTHER_MODULE_ACTIVE',
  'WRITEBACK_UNDO_FACE_FAILED',
  'WRITEBACK_FAILURES_PENDING',
  'WRITEBACK_GROUP_NOT_IN_SESSION',
  // Export validation
  'EXPORT_PARAMS_INVALID',
  'EXPORT_CONFIRMATION_REQUIRED',
  'EXPORT_DIR_INVALID',
  'EXPORT_DIR_ABSOLUTE_REQUIRED',
  'EXPORT_DIR_ROOT_FORBIDDEN',
  'EXPORT_DIR_INSIDE_SESSION',
  'EXPORT_FORMAT_INVALID',
  'EXPORT_FORMAT_UNSUPPORTED',
  'EXPORT_VARIANT_POLICY_INVALID',
  'EXPORT_ORIGINAL_NO_TRANSFORM',
  'EXPORT_NAMING_EMPTY',
  'EXPORT_NAMING_INVALID_CHARS',
  'EXPORT_JPEG_QUALITY_INVALID',
  'EXPORT_MAX_DIMENSION_INVALID',
  'EXPORT_START_INDEX_INVALID',
  'EXPORT_WATERMARK_TYPE_UNSUPPORTED',
  'EXPORT_WATERMARK_TEXT_EMPTY',
  'EXPORT_WATERMARK_OPACITY_INVALID',
  'EXPORT_WATERMARK_FONT_SIZE_INVALID',
  'EXPORT_XMP_CONFLICT',
  'EXPORT_PATH_INVALID',
  'EXPORT_SCOPE_UNSUPPORTED',
  'EXPORT_SCOPE_UNKNOWN',
  'EXPORT_RAW_CONVERT_UNSUPPORTED',
  'EXPORT_UNKNOWN_ERROR',
  // Navigation
  'NAV_BURST_GAP_INVALID',
  'NAV_SCENE_GAP_INVALID',
  // Culling + culling history
  'CULLING_EMPTY_SELECTION',
  'CULLING_PHOTOS_NOT_IN_SESSION',
  'CULLING_HISTORY_NOT_FOUND',
  'CULLING_HISTORY_ALREADY_UNDONE',
  'CULLING_HISTORY_NOT_UNDONE',
  'CULLING_HISTORY_DIVERGED',
  'CULLING_HISTORY_STALE',
  'CULLING_HISTORY_CORRUPT',
  'CULLING_UNDO_NOT_LATEST',
  'CULLING_REDO_OUT_OF_ORDER',
  'CULLING_NO_SIMILARITY',
  'CULLING_GROUP_TOO_SMALL',
  'CULLING_KEEP_NOT_IN_GROUP',
  // Asset relink
  'ASSET_RELINK_XMP_BUSY',
  'ASSET_RELINK_OUTBOX_CONFLICT',
  'ASSET_RELINK_XMP_CONFLICT',
  // Face keyword service + model downloader
  'FACE_EPS_INVALID',
  'FACE_MIN_CLUSTER_INVALID',
  'FACE_NO_PHOTOS',
  'FACE_SELF_MERGE',
  'FACE_MODEL_DETECTOR_CORRUPT',
  'FACE_MODEL_ENCODER_CORRUPT',
  // Similarity
  'SIM_THRESHOLD_INVALID',
  'SIM_MIN_GROUP_INVALID',
  'SIM_WRITEBACK_EMPTY',
  'SIM_WRITEBACK_INVALID_ITEM',
  'SIM_ANALYSIS_MISSING',
  'SIM_THRESHOLD_NO_RESULTS',
  'SIM_PREVIEW_REQUIRED',
  'SIM_PREVIEW_STALE',
  // Navigation
  'NAV_GROUP_NOT_FOUND',
  'NAV_SPLIT_OUT_OF_GROUP',
  'NAV_MERGE_MIN_TWO',
  'NAV_MERGE_TYPE_MISMATCH',
  // Session sources + identity
  'SESSION_SOURCE_NOT_DIR',
  'SESSION_SOURCE_ROOT_FORBIDDEN',
  'SESSION_NOT_FOUND',
  'SESSION_IDS_REQUIRED',
  // Culling
  'CULLING_PHOTO_NOT_IN_SESSION',
  'CULLING_REVISION_CONFLICT',
  'CULLING_PATCH_INVALID',
  'CULLING_INVALID_SCOPE',
  'CULLING_FINALIZE_CONFIRM_REQUIRED',
  'CULLING_RESET_CONFIRM_REQUIRED',
  'CULLING_NO_DECISIONS',
  // Writeback / cleanup confirmations
  'WRITEBACK_CONFIRM_REQUIRED',
  'WRITEBACK_RETRY_CONFIRM_REQUIRED',
  'WRITEBACK_CLEANUP_CONFIRM_REQUIRED',
  'FKW_UNBIND_CONFIRM_REQUIRED',
  'FKW_CLEANUP_CONFIRM_REQUIRED',
  // Face keyword service
  'FKW_NO_OBSERVATIONS',
  'FKW_ANALYSIS_RUNNING',
  'FKW_CLUSTER_NOT_FOUND',
  'FKW_CLUSTER_NOT_IN_SESSION',
  'FKW_CLUSTER_MEMBER_NOT_FOUND',
  'FKW_ROLE_NAME_EMPTY',
  'FKW_KEYWORDS_INVALID',
  'FKW_ITEMS_INVALID',
  // Similarity
  'SIM_ANALYSIS_RUNNING',
  'SIM_NO_PHOTOS',
  'SIM_NO_HASH_DATA',
  'SIM_NO_HASH_RECLUSTER',
  'SIM_NO_RESULTS',
  'SIM_ASSIGNMENT_INVALID',
  'SIM_GROUPING_MODE_INVALID',
  // Duplicate / metadata / jobs / settings / quality / index / asset
  'DUP_RESOLVE_CONFIRM_REQUIRED',
  'DUP_RESOLVE_MEMBER_CONFIRM_REQUIRED',
  'METADATA_SET_CONFIRM_REQUIRED',
  'METADATA_BATCH_SET_CONFIRM_REQUIRED',
  'METADATA_RESOLVE_CONFLICT_CONFIRM_REQUIRED',
  'METADATA_RESOLVE_ORPHAN_CONFIRM_REQUIRED',
  'JOBS_CLEAR_CONFIRM_REQUIRED',
  'SETTINGS_LANGUAGE_INVALID',
  'QUALITY_NO_ASSET_FILE',
  'INDEX_SESSION_NO_SOURCE',
  'ASSET_LINK_CANDIDATE_NOT_FOUND',
  'ASSET_FILE_NOT_LINKED',
] as const

export type GatherErrorCode = (typeof GATHER_ERROR_CODES)[number]

export function isGatherErrorCode(value: unknown): value is GatherErrorCode {
  return typeof value === 'string' && (GATHER_ERROR_CODES as readonly string[]).includes(value)
}

export type Result<T, E = Error> = { ok: true; data: T } | { ok: false; error: E }

export function ok<T>(data: T): Result<T, never> {
  return { ok: true, data }
}

export function errResult<E>(error: E): Result<never, E> {
  return { ok: false, error }
}
