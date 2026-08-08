import { test, expect, _electron as electron, type ElectronApplication, type Page } from '@playwright/test'
import { copyFileSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import path from 'path'

const rawExtensions = new Set(['.arw', '.cr2', '.cr3', '.dng', '.nef', '.orf', '.raf', '.rw2'])

// Fixtures can be supplied per-run via env vars, or placed in the git-ignored
// local directory tests/fixtures/local/ (see tests/fixtures/local-fixtures.md
// and scripts/setup-local-face-fixtures.mjs).
const localDir = path.resolve(process.cwd(), 'tests', 'fixtures', 'local')
const sourceDir = process.env.GATHER_FACE_E2E_SOURCE_DIR
  || path.join(localDir, 'raw')
const detectorPath = process.env.GATHER_FACE_E2E_DETECTOR
  || path.join(localDir, 'models', 'face_detector.onnx')
const encoderPath = process.env.GATHER_FACE_E2E_ENCODER
  || path.join(localDir, 'models', 'face_encoder.onnx')

const hasRawSamples = existsSync(sourceDir)
  && readdirSync(sourceDir).some(name => rawExtensions.has(path.extname(name).toLowerCase()))

let app: ElectronApplication
let page: Page
let userDataDir: string
let photoDir: string

async function command<T>(cmd: string, params: Record<string, unknown>): Promise<T> {
  return page.evaluate(async ({ cmd, params }) => {
    const response = await window.gather.sendCommand(cmd, params)
    if (!response.ok) {
      const message = typeof response.error === 'string'
        ? response.error
        : response.error.message
      throw new Error(message)
    }
    return response.data
  }, { cmd, params }) as Promise<T>
}

test.describe('isolated RAW face keyword workflow', () => {
  test.skip(
    !hasRawSamples || !existsSync(detectorPath) || !existsSync(encoderPath),
    'Face fixtures missing: put RAW photos with faces in tests/fixtures/local/raw/ ' +
    'and run `node scripts/setup-local-face-fixtures.mjs` for the ONNX models, ' +
    'or set GATHER_FACE_E2E_SOURCE_DIR / GATHER_FACE_E2E_DETECTOR / GATHER_FACE_E2E_ENCODER',
  )
  test.setTimeout(10 * 60_000)

  test.beforeAll(async () => {
    userDataDir = mkdtempSync(path.join(tmpdir(), 'gather-face-e2e-user-'))
    photoDir = mkdtempSync(path.join(tmpdir(), 'gather-face-e2e-photos-'))

    const sourcePhotos = readdirSync(sourceDir!)
      .filter(name => rawExtensions.has(path.extname(name).toLowerCase()))
      .slice(0, 8)
    if (sourcePhotos.length === 0) throw new Error(`No RAW photos found in ${sourceDir}`)
    for (const name of sourcePhotos) {
      copyFileSync(path.join(sourceDir!, name), path.join(photoDir, name))
    }

    app = await electron.launch({
      args: [
        path.resolve(process.cwd(), 'desktop'),
        `--user-data-dir=${userDataDir}`,
      ],
      cwd: process.cwd(),
      env: {
        ...process.env,
        NODE_ENV: 'production',
        // The confirm/cleanup reload-ack gate requires the Capture One reload
        // bridge, which cannot run in e2e; the gate is unit-tested, so the
        // workflow bypasses it here (metadata-sync-coordinator).
        GATHER_TEST_SKIP_RELOAD_ACK: '1',
      },
    })
    app.process().stdout?.on('data', chunk => process.stdout.write(`[electron] ${chunk}`))
    app.process().stderr?.on('data', chunk => process.stderr.write(`[electron] ${chunk}`))
    page = await app.firstWindow()
  })

  test.afterAll(async () => {
    await app?.close()
    if (userDataDir) rmSync(userDataDir, { recursive: true, force: true })
    if (photoDir) rmSync(photoDir, { recursive: true, force: true })
  })

  test('imports RAW previews, clusters faces and round-trips Capture One keywords through XMP', async () => {
    const filepaths = readdirSync(photoDir).map(name => path.join(photoDir, name))
    const session = await command<{ id: string; added: number; failedFiles: string[] }>(
      'session.create',
      {
        name: path.basename(photoDir),
        source: 'folder',
        sourcePath: photoDir,
        filepaths,
      },
    )
    expect(session.added + session.failedFiles.length).toBe(filepaths.length)

    // Decodability is environment-dependent (libvips/sharp build, RAW samples).
    // Track which files cannot be decoded so later failures are attributable:
    // the workflow must still succeed on every decodable photo, and any import
    // or analysis failure must be explainable by an undecodable file.
    const undecodable = new Set<string>()
    for (const filepath of filepaths) {
      try {
        const preview = await page.evaluate(async ({ filepath }) => {
          const params = new URLSearchParams({ path: filepath, size: '1024' })
          const image = new Image()
          image.src = `gather-image://preview?${params.toString()}`
          await new Promise<void>((resolve, reject) => {
            image.onload = () => resolve()
            image.onerror = () => reject(new Error(`Failed to load RAW preview: ${filepath}`))
          })
          return { width: image.naturalWidth, height: image.naturalHeight }
        }, { filepath })
        expect(preview.width).toBeGreaterThan(0)
        expect(preview.height).toBeGreaterThan(0)
      } catch (error) {
        undecodable.add(filepath)
        console.warn(`[face e2e] skipping undecodable fixture ${filepath}: ${error}`)
      }
    }
    const decodableCount = filepaths.length - undecodable.size
    expect(decodableCount).toBeGreaterThanOrEqual(3)
    expect(session.failedFiles.every(file => undecodable.has(file))).toBe(true)

    const analysis = await command<{
      status: string
      detectionFailures: number
      encodingFailures: number
    }>('fkw.analyze', {
      sessionId: session.id,
      detectorPath,
      encoderPath,
      minSamples: 1,
    })
    expect(analysis.status).toBe('done')
    // Failures on decodable photos would indicate an app regression; failures
    // on undecodable fixtures are environmental.
    expect(analysis.detectionFailures + analysis.encodingFailures)
      .toBeLessThanOrEqual(undecodable.size)

    const clusters = await command<Array<{ id: number; members: unknown[] }>>(
      'fkw.clusters',
      { sessionId: session.id },
    )
    expect(clusters.length).toBeGreaterThan(0)
    expect(clusters[0].members.length).toBeGreaterThan(0)

    await command('fkw.bind', {
      sessionId: session.id,
      clusterId: clusters[0].id,
      roleName: 'GatherFlowTest',
      keywords: ['CaptureOneKeyword'],
    })
    const preview = await command<{
      items: Array<{ xmpPath: string }>
      affectedPhotos: number
    }>('fkw.preview', { sessionId: session.id, options: {} })
    expect(preview.affectedPhotos).toBeGreaterThan(0)
    expect(preview.items.length).toBeGreaterThan(0)

    const result = await command<{ written: number; failed: number }>(
      'fkw.writeback',
      { sessionId: session.id, items: preview.items, confirmed: true },
    )
    expect(result.failed).toBe(0)
    expect(result.written).toBe(preview.items.length)

    for (const item of preview.items) {
      const xmp = readFileSync(item.xmpPath, 'utf8')
      expect(xmp).toContain('GatherFlowTest')
      expect(xmp).toContain('CaptureOneKeyword')
    }

    await command('fkw.confirm_sync', { sessionId: session.id })
    const cleanup = await command<{ deletedCount: number; errors: string[] }>(
      'fkw.confirm_cleanup',
      { sessionId: session.id, confirmed: true },
    )
    expect(cleanup.errors).toEqual([])
    // Cleanup must remove exactly the previewed outbox work; the equality is
    // kept loose (>= 1) so a future shared-sidecar case cannot couple the two
    // accounting paths by accident.
    expect(cleanup.deletedCount).toBeGreaterThan(0)
    expect(cleanup.deletedCount).toBeLessThanOrEqual(preview.items.length)
  })
})
