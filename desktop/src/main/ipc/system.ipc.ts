import sharp from 'sharp'
import type { CommandRegistry } from './registry'
import type { ResponseOk, ResponseErr } from '@gather/shared'

function ok<T>(data: T): ResponseOk<T> {
  return { ok: true, data }
}

function err(error: string): ResponseErr {
  return { ok: false, error }
}

function wrapHandler(handler: (params: Record<string, unknown>) => unknown) {
  return async (params: unknown) => {
    try {
      return await handler((params ?? {}) as Record<string, unknown>)
    } catch (e: unknown) {
      const message = e instanceof Error ? e.message : 'Unknown error'
      return err(message)
    }
  }
}

export function registerSystemHandlers(registry: CommandRegistry): void {
  registry.register(
    'thumbnail.get',
    wrapHandler(async (params) => {
      const { path: imagePath } = params as { path: string }
      const buffer = await sharp(imagePath).resize(200, 200, { fit: 'cover' }).jpeg({ quality: 80 }).toBuffer()
      return ok(buffer.toString('base64'))
    }),
  )
}
