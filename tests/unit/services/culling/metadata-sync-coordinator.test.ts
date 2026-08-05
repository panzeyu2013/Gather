import { describe, expect, it, vi } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { MetadataSyncCoordinator } from '../../../../desktop/src/main/services/metadata/metadata-sync-coordinator'

describe('MetadataSyncCoordinator.finalizeSession', () => {
  it('deletes the outbox row before unlinking the backup so a new mutation survives', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-finalize-'))
    try {
      // Point the backup at a directory: unlink() fails with EISDIR. In the
      // fixed implementation the outbox row is deleted before unlink, so the
      // deletion is observable even though unlink throws. In the buggy order
      // (delete after the async unlink) the throw would happen first and the
      // delete would never run.
      const backupPath = path.join(dir, 'backup')
      fs.mkdirSync(backupPath, { recursive: true })

      // Simulates the single per-xmp_path outbox row. A new rating arriving
      // after the synced row is deleted re-inserts a fresh pending row.
      let state: { status: string; revision: number } = { status: 'synced', revision: 1 }
      const baseRow = {
        xmp_path: path.join(dir, 'photo.xmp'),
        photo_path: path.join(dir, 'photo.NEF'),
        backup_path: backupPath,
      }
      const repo = {
        getBySession: vi.fn(() => [{ ...baseRow, ...state }]),
        get: vi.fn(() => ({ ...baseRow, ...state })),
        delete: vi.fn(() => {
          state = { status: 'pending', revision: 2 }
        }),
      }
      const coordinator = new MetadataSyncCoordinator(
        repo as never,
        {} as never,
        {} as never,
        { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
        {} as never,
      )

      await expect(coordinator.finalizeSession('session')).rejects.toThrow()

      // The synced row was deleted first (despite the backup unlink failing),
      // and the re-inserted pending transaction was never deleted.
      expect(repo.delete).toHaveBeenCalledTimes(1)
      expect(repo.delete).toHaveBeenCalledWith(baseRow.xmp_path)
      expect(state).toEqual({ status: 'pending', revision: 2 })
    } finally {
      fs.rmSync(dir, { recursive: true, force: true })
    }
  })
})
