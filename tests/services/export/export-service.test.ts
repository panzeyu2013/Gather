import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import fs from 'fs'
import os from 'os'
import path from 'path'
import { ExportService } from '../../../desktop/src/main/services/export/export.service'
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
})
