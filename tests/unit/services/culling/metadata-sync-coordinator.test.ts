import { describe, expect, it, vi } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { MetadataSyncCoordinator } from '../../../../desktop/src/main/services/metadata/metadata-sync-coordinator'

describe('MetadataSyncCoordinator.finalizeSession', () => {
  it('keeps the outbox row when the backup unlink fails, so finalize can be retried', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-finalize-'))
    try {
      // Point the backup at a directory: unlink() fails with EISDIR. The row
      // must survive the failed unlink (with its backup_path intact), so a
      // later finalize retry can still remove the backup — deleting the row
      // first would leak the .gather-backup file forever.
      const backupPath = path.join(dir, 'backup')
      fs.mkdirSync(backupPath, { recursive: true })

      let state: { status: string; revision: number } = { status: 'synced', revision: 1 }
      const baseRow = {
        xmp_path: path.join(dir, 'photo.xmp'),
        photo_path: path.join(dir, 'photo.NEF'),
        backup_path: backupPath,
      }
      const repo = {
        getBySession: vi.fn(() => [{ ...baseRow, ...state }]),
        get: vi.fn(() => ({ ...baseRow, ...state })),
        deleteByRevision: vi.fn((_xmpPath: string, revision: number) => {
          if (revision === state.revision) {
            state = { status: 'pending', revision: 2 }
          }
        }),
        clearBackupPath: vi.fn(),
      }
      const coordinator = new MetadataSyncCoordinator(
        repo as never,
        {} as never,
        {} as never,
        { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
        {} as never,
      )

      await expect(coordinator.finalizeSession('session')).rejects.toThrow()

      // The row was not deleted: the failed unlink left it in place so the
      // finalize can be retried (the backup file is still there to remove).
      expect(repo.deleteByRevision).not.toHaveBeenCalled()
      expect(state).toEqual({ status: 'synced', revision: 1 })
    } finally {
      fs.rmSync(dir, { recursive: true, force: true })
    }
  })

  it('deletes the row by revision after a successful unlink, leaving a concurrent mutation untouched', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-finalize-ok-'))
    try {
      const backupPath = path.join(dir, 'backup')
      fs.writeFileSync(backupPath, 'original')

      let state: { status: string; revision: number } = { status: 'synced', revision: 1 }
      const baseRow = {
        xmp_path: path.join(dir, 'photo.xmp'),
        photo_path: path.join(dir, 'photo.NEF'),
        backup_path: backupPath,
      }
      const repo = {
        getBySession: vi.fn(() => [{ ...baseRow, ...state }]),
        get: vi.fn(() => ({ ...baseRow, ...state })),
        deleteByRevision: vi.fn((_xmpPath: string, revision: number) => {
          if (revision === state.revision) {
            state = { status: 'cleaned', revision: 2 }
          }
        }),
        clearBackupPath: vi.fn(),
      }
      const coordinator = new MetadataSyncCoordinator(
        repo as never,
        {} as never,
        {} as never,
        { getNumber: vi.fn((_key: string, fallback: number) => fallback) } as never,
        {} as never,
      )

      await coordinator.finalizeSession('session')

      // Backup removed first, then the exact row (matching revision) deleted.
      expect(fs.existsSync(backupPath)).toBe(false)
      expect(repo.deleteByRevision).toHaveBeenCalledTimes(1)
      expect(repo.deleteByRevision).toHaveBeenCalledWith(baseRow.xmp_path, 1)
      expect(state.status).toBe('cleaned')
    } finally {
      fs.rmSync(dir, { recursive: true, force: true })
    }
  })
})
