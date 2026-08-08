import fs from 'fs'
import os from 'os'
import path from 'path'
import { afterEach, describe, expect, expectTypeOf, it, vi } from 'vitest'
import type { SessionCreateFromDirectoryParams } from '../../../packages/shared/src/protocol/session'

const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-session-dir-'))

vi.mock('electron', () => ({
  app: {
    getPath: () => userDataDir,
  },
}))

import { Database } from '../../../desktop/src/main/db/database'
import { runMigrations } from '../../../desktop/src/main/db/migrations'
import { SessionRepository } from '../../../desktop/src/main/db/repositories/session.repo'
import { PhotoRepository } from '../../../desktop/src/main/db/repositories/photo.repo'
import { FaceRepository } from '../../../desktop/src/main/db/repositories/face.repo'
import { SessionService } from '../../../desktop/src/main/services/session/session.service'
import { CommandRegistry } from '../../../desktop/src/main/ipc/registry'
import { registerSessionHandlers } from '../../../desktop/src/main/ipc/session.ipc'
import type { ImageService } from '../../../desktop/src/main/services/image'
import type { SettingsService } from '../../../desktop/src/main/services/settings/settings.service'
import type { JobService } from '../../../desktop/src/main/services/jobs/job.service'

const tempDirs: string[] = []
let db: Database
let service: SessionService

function makeTempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-import-'))
  tempDirs.push(dir)
  return dir
}

async function makeService(): Promise<SessionService> {
  db = new Database()
  await runMigrations(db)
  const settings = {
    getNumber: () => 8,
  } as unknown as SettingsService
  return new SessionService(
    new SessionRepository(db),
    new PhotoRepository(db),
    new FaceRepository(db, settings),
    settings,
    {} as unknown as ImageService,
    db,
  )
}

describe('SessionService.createFromDirectory (one-hop import)', () => {
  it('creates a local session row with source_path and inserts no photos', async () => {
    service = await makeService()
    const dir = makeTempDir()
    fs.writeFileSync(path.join(dir, 'a.jpg'), 'x')
    fs.writeFileSync(path.join(dir, 'b.jpg'), 'x')

    const session = await service.createFromDirectory('Wedding', dir)

    expect(session.name).toBe('Wedding')
    expect(session.importSource).toBe('local')
    expect(session.sourcePath).toBe(path.resolve(dir))
    expect(session.photoCount).toBe(0)
    expect(session.truncatedImport).toBe(false)
    // Photos are NOT inserted at create time — the metadata.scan index job
    // fills the session in the background.
    expect(service.getSession(session.id)?.photoCount).toBe(0)
    expect(service.listSessions()).toHaveLength(1)
  })

  it('derives the session name from the directory basename when name is empty', async () => {
    service = await makeService()
    const dir = makeTempDir()
    fs.writeFileSync(path.join(dir, 'a.jpg'), 'x')

    const session = await service.createFromDirectory('   ', dir)

    expect(session.name).toBe(path.basename(path.resolve(dir)))
  })

  it('rejects a non-directory path', async () => {
    service = await makeService()
    const dir = makeTempDir()
    const filePath = path.join(dir, 'a.jpg')
    fs.writeFileSync(filePath, 'x')

    await expect(service.createFromDirectory('X', filePath)).rejects.toThrow('SESSION_SOURCE_NOT_DIR')
  })

  it('rejects a filesystem root as the source path', async () => {
    service = await makeService()
    const dir = makeTempDir()

    await expect(
      service.createFromDirectory('X', path.parse(dir).root),
    ).rejects.toThrow('SESSION_SOURCE_ROOT_FORBIDDEN')
  })

  it('carries no file array in the one-hop command payload type', () => {
    // The protocol type itself is the guarantee: the payload is exactly
    // { name?, sourcePath } — `toEqualTypeOf` fails at compile time if a
    // filepaths field is ever reintroduced, and the shape is re-checked by
    // `npm run typecheck` on the shared package.
    expectTypeOf<SessionCreateFromDirectoryParams>().toEqualTypeOf<{
      name?: string
      sourcePath: string
    }>()
  })
})

describe('session.create_from_directory IPC handler (one-hop wiring)', () => {
  it('enqueues the metadata.scan job with the session-scoped dedupe key', async () => {
    service = await makeService()
    const dir = makeTempDir()
    fs.writeFileSync(path.join(dir, 'a.jpg'), 'x')
    const registry = new CommandRegistry()
    const before = service.listSessions().length
    const created: unknown[] = []
    const jobs = {
      create: (params: unknown) => { created.push(params) },
    } as unknown as JobService
    registerSessionHandlers(registry, service, jobs)

    const response = await registry.execute(
      'session.create_from_directory',
      { name: 'Wedding', sourcePath: dir },
    ) as { ok: boolean; data?: { id: string } }

    expect(response.ok).toBe(true)
    expect(service.listSessions().length).toBe(before + 1)
    expect(created).toEqual([{
      type: 'metadata.scan',
      scopeType: 'session',
      scopeId: response.data?.id,
      dedupeKey: `metadata.scan:${response.data?.id}`,
    }])
  })

  it('rolls the session row back when the scan job cannot be enqueued', async () => {
    service = await makeService()
    const dir = makeTempDir()
    fs.writeFileSync(path.join(dir, 'a.jpg'), 'x')
    const registry = new CommandRegistry()
    const before = service.listSessions().length
    const jobs = {
      create: () => { throw new Error('enqueue failed') },
    } as unknown as JobService
    registerSessionHandlers(registry, service, jobs)

    const response = await registry.execute(
      'session.create_from_directory',
      { name: 'Wedding', sourcePath: dir },
    ) as { ok: boolean; error?: { message: string } }

    // 回归：入队失败必须删除刚创建的 session 行，否则列表里会出现
    // 永远不会被索引的半成品工作区（孤儿 session）。
    expect(response.ok).toBe(false)
    expect(response.error?.message).toBe('enqueue failed')
    expect(service.listSessions().length).toBe(before)
  })
})

afterEach(() => {
  db?.close()
  for (const dir of tempDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
