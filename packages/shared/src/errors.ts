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

export type Result<T, E = Error> = { ok: true; data: T } | { ok: false; error: E }

export function ok<T>(data: T): Result<T, never> {
  return { ok: true, data }
}

export function errResult<E>(error: E): Result<never, E> {
  return { ok: false, error }
}
