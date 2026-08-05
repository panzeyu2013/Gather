import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import fs from 'fs'
import os from 'os'
import path from 'path'
import { ExportService } from '../../../../desktop/src/main/services/export/export.service'
import type { ExportOptions } from '@gather/shared'

describe('ExportService option contracts', () => {
  let dir: string
  let source: string
  let destination: string

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'gather-export-'))
    source = path.join(dir, 'source.NEF')
    destination = path.join(dir, 'output')
    fs.writeFileSync(source, 'raw bytes')
  })

  afterEach(() => {
    fs.rmSync(dir, { recursive: true, force: true })
  })

  function makeService(): ExportService {
    return new ExportService(
      {
        getBySession: () => [{
          id: 'photo-1',
          session_id: 'session-1',
          filepath: source,
          filename: 'source.NEF',
          status: 'ready',
        }],
      } as never,
      {
        get: () => ({ name: 'Wedding' }),
      } as never,
    )
  }

  function options(overrides: Partial<ExportOptions> = {}): ExportOptions {
    return {
      scope: 'session',
      format: 'original',
      naming: { pattern: '{session}_{original}' },
      includeXmp: false,
      destination,
      ...overrides,
    }
  }

  it('rejects transformations that cannot apply to original copies', async () => {
    await expect(makeService().preview('session-1', options({ maxDimension: 1200 })))
      .rejects.toThrow('保持原格式')
    await expect(makeService().preview('session-1', options({
      watermark: {
        type: 'text',
        content: 'Gather',
        position: 'bottom-right',
        opacity: 0.5,
      },
    }))).rejects.toThrow('保持原格式')
  })

  it('creates missing destination directories and uses the real session name', async () => {
    const result = await makeService().execute('session-1', options())
    expect(result).toMatchObject({ exported: 1, failed: 0 })
    expect(fs.readFileSync(path.join(destination, 'Wedding_source.NEF'), 'utf8'))
      .toBe('raw bytes')
  })

  it('does not overwrite an occupied incomplete destination when resuming', async () => {
    const service = makeService()
    const destinations: Record<string, string> = {}
    await service.execute('session-1', options(), undefined, {
      destinations,
      onPlanned: (photoId, destinationName) => {
        destinations[photoId] = destinationName
      },
    })
    expect(destinations).toEqual({ 'photo-1': 'Wedding_source.NEF' })

    fs.writeFileSync(source, 'resumed raw bytes')
    const resumed = await service.execute('session-1', options(), undefined, {
      destinations,
      completedPhotoIds: new Set(),
      onPlanned: (photoId, destinationName) => {
        destinations[photoId] = destinationName
      },
    })
    expect(resumed).toMatchObject({ exported: 1, failed: 0 })
    expect(fs.readFileSync(path.join(destination, 'Wedding_source.NEF'), 'utf8'))
      .toBe('raw bytes')
    expect(fs.readFileSync(path.join(destination, 'Wedding_source_2.NEF'), 'utf8'))
      .toBe('resumed raw bytes')
    expect(destinations).toEqual({ 'photo-1': 'Wedding_source_2.NEF' })
  })

  it('rejects unsafe names and invalid numeric options before writing', async () => {
    await expect(makeService().preview(
      'session-1',
      options({ naming: { pattern: '../outside' } }),
    )).rejects.toThrow('路径分隔符')
    await expect(makeService().preview(
      'session-1',
      options({ format: 'jpeg', quality: Number.NaN }),
    )).rejects.toThrow('JPEG 质量')
  })

  it('selects RAW, JPEG, preferred, or all members of a logical Asset', async () => {
    const jpeg = path.join(dir, 'source.JPG')
    fs.writeFileSync(jpeg, 'jpeg bytes')
    const service = new ExportService(
      {
        getBySession: () => [
          {
            id: 'raw',
            asset_id: 'asset',
            session_id: 'session-1',
            filepath: source,
            filename: 'source.NEF',
            status: 'ready',
          },
          {
            id: 'jpeg',
            asset_id: 'asset',
            session_id: 'session-1',
            filepath: jpeg,
            filename: 'source.JPG',
            status: 'ready',
          },
        ],
      } as never,
      { get: () => ({ name: 'Wedding' }) } as never,
    )

    expect((await service.preview(
      'session-1',
      options({ variantPolicy: 'preferred' }),
    )).files.map(file => file.photoId)).toEqual(['raw'])
    expect((await service.preview(
      'session-1',
      options({ variantPolicy: 'jpeg' }),
    )).files.map(file => file.photoId)).toEqual(['jpeg'])
    expect((await service.preview(
      'session-1',
      options({ variantPolicy: 'all' }),
    )).files.map(file => file.photoId)).toEqual(['raw', 'jpeg'])
  })

  it('rejects exporting into the session source directory or its subdirectories', async () => {
    const sourceDir = path.join(dir, 'workspace')
    fs.mkdirSync(sourceDir, { recursive: true })
    const subDir = path.join(sourceDir, 'nested')
    fs.mkdirSync(subDir, { recursive: true })
    const service = new ExportService(
      {
        getBySession: () => [{
          id: 'photo-1',
          session_id: 'session-1',
          filepath: path.join(sourceDir, 'source.NEF'),
          filename: 'source.NEF',
          status: 'ready',
        }],
      } as never,
      { get: () => ({ name: 'Wedding', source_path: sourceDir }) } as never,
    )

    await expect(service.preview('session-1', options({ destination: sourceDir })))
      .rejects.toThrow('重新导入')
    await expect(service.preview('session-1', options({ destination: subDir })))
      .rejects.toThrow('重新导入')
    await expect(service.execute('session-1', options({ destination: sourceDir })))
      .rejects.toThrow('重新导入')
    await expect(service.execute('session-1', options({ destination: subDir })))
      .rejects.toThrow('重新导入')
  })

  it('rejects a destination reached through a symlink into the source directory', async () => {
    const sourceDir = path.join(dir, 'workspace')
    fs.mkdirSync(sourceDir, { recursive: true })
    const link = path.join(dir, 'source-link')
    try {
      fs.symlinkSync(sourceDir, link, 'dir')
    } catch {
      // Symlinks are unavailable on this platform (e.g. Windows without admin):
      // skip the test rather than fail.
      return
    }
    const service = new ExportService(
      {
        getBySession: () => [{
          id: 'photo-1',
          session_id: 'session-1',
          filepath: path.join(sourceDir, 'source.NEF'),
          filename: 'source.NEF',
          status: 'ready',
        }],
      } as never,
      { get: () => ({ name: 'Wedding', source_path: sourceDir }) } as never,
    )

    await expect(service.preview('session-1', options({ destination: link })))
      .rejects.toThrow('重新导入')
    await expect(service.execute('session-1', options({ destination: link })))
      .rejects.toThrow('重新导入')
  })
})
