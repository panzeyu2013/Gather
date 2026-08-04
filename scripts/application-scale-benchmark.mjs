import { _electron as electron } from '@playwright/test'
import { execFileSync } from 'node:child_process'
import { mkdir, mkdtemp, rm, stat, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { performance } from 'node:perf_hooks'
import sharp from 'sharp'

const defaultSizes = [500, 5_000, 10_000]
const sizes = process.env.GATHER_BENCHMARK_SIZES
  ? process.env.GATHER_BENCHMARK_SIZES.split(',').map(Number).filter(Number.isFinite)
  : defaultSizes
const appPath = path.resolve(process.cwd(), 'desktop')
// A decodable placeholder photo: the decoders (sharp/sips) reject many tiny
// hand-crafted 1x1 JPEGs ("Invalid SOS parameters"), which made every
// thumbnail protocol request fail. Generate a real solid-color JPEG instead.
const jpeg = await sharp({
  create: { width: 160, height: 90, channels: 3, background: '#406080' },
}).jpeg().toBuffer()

async function createPhotos(root, count) {
  await mkdir(root, { recursive: true })
  const paths = Array.from(
    { length: count },
    (_, index) => path.join(root, `IMG_${String(index + 1).padStart(6, '0')}.jpg`),
  )
  for (let offset = 0; offset < paths.length; offset += 256) {
    await Promise.all(paths.slice(offset, offset + 256).map(filePath => writeFile(filePath, jpeg)))
  }
  return paths
}

function processTreeRssBytes(rootPid) {
  try {
    const rows = execFileSync('ps', ['-axo', 'pid=,ppid=,rss='], { encoding: 'utf8' })
      .trim()
      .split(/\r?\n/)
      .map(line => line.trim().split(/\s+/).map(Number))
      .filter(parts => parts.length === 3 && parts.every(Number.isFinite))
    const descendants = new Set([rootPid])
    let changed = true
    while (changed) {
      changed = false
      for (const [pid, ppid] of rows) {
        if (descendants.has(ppid) && !descendants.has(pid)) {
          descendants.add(pid)
          changed = true
        }
      }
    }
    return rows
      .filter(([pid]) => descendants.has(pid))
      .reduce((total, [, , rssKb]) => total + rssKb * 1024, 0)
  } catch {
    return 0
  }
}

async function command(page, type, params = {}) {
  return page.evaluate(async ({ commandType, commandParams }) => {
    const response = await window.gather.sendCommand(commandType, commandParams)
    if (!response.ok) {
      throw new Error(typeof response.error === 'string' ? response.error : response.error.message)
    }
    return response.data
  }, { commandType: type, commandParams: params })
}

async function waitForJob(page, jobId, timeoutMs = 180_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const jobs = await command(page, 'jobs.list')
    const job = jobs.find(candidate => candidate.id === jobId)
    if (job && ['succeeded', 'failed', 'cancelled', 'interrupted'].includes(job.status)) {
      if (job.status !== 'succeeded') throw new Error(`${job.type} ended as ${job.status}: ${job.errorMessage}`)
      return job
    }
    await new Promise(resolve => setTimeout(resolve, 100))
  }
  throw new Error(`Timed out waiting for job ${jobId}`)
}

async function launch(userDataDir) {
  const started = performance.now()
  const app = await electron.launch({
    args: [appPath, `--user-data-dir=${userDataDir}`],
    cwd: process.cwd(),
    env: { ...process.env, NODE_ENV: 'production' },
  })
  const page = await app.firstWindow()
  await page.getByText('工作台', { exact: true }).waitFor()
  await page.evaluate(() => {
    globalThis.__gatherBenchmarkLongestTask = 0
    try {
      const observer = new PerformanceObserver(list => {
        for (const entry of list.getEntries()) {
          globalThis.__gatherBenchmarkLongestTask = Math.max(
            globalThis.__gatherBenchmarkLongestTask,
            entry.duration,
          )
        }
      })
      observer.observe({ entryTypes: ['longtask'] })
      globalThis.__gatherBenchmarkObserver = observer
    } catch {
      // Long-task entries are unavailable on some Chromium builds.
    }
  })
  return { app, page, firstWindowMs: performance.now() - started }
}

async function benchmark(count) {
  const root = await mkdtemp(path.join(os.tmpdir(), `gather-scale-${count}-`))
  const source = path.join(root, 'photos')
  const userData = path.join(root, 'user-data')
  const paths = await createPhotos(source, count)
  let peakRssBytes = 0
  let launched = await launch(userData)
  const firstWindowMs = launched.firstWindowMs
  const sample = setInterval(() => {
    peakRssBytes = Math.max(peakRssBytes, processTreeRssBytes(launched.app.process().pid))
  }, 100)
  try {
    const importStarted = performance.now()
    const session = await command(launched.page, 'session.create', {
      name: `Scale ${count}`,
      source: 'folder',
      sourcePath: source,
      filepaths: paths,
    })
    const importMs = performance.now() - importStarted

    const renderStarted = performance.now()
    await launched.page.evaluate(id => {
      window.location.hash = `#/sessions/${id}/gallery`
    }, session.id)
    await launched.page.locator('img').first().waitFor({ state: 'visible' })
    await launched.page.waitForFunction(
      () => document.querySelector('img')?.naturalWidth,
    )
    const firstGalleryInteractiveMs = performance.now() - renderStarted

    const initialIndex = await command(launched.page, 'index.scan', {
      sessionId: session.id,
      confirmed: true,
    })
    await waitForJob(launched.page, initialIndex.id)

    const thumbnailPaths = paths.slice(0, Math.min(500, paths.length))
    const thumbnailStarted = performance.now()
    const thumbnailJob = await command(launched.page, 'image.preload_thumbnails', {
      paths: thumbnailPaths,
      size: 256,
    })
    if (thumbnailJob?.id) await waitForJob(launched.page, thumbnailJob.id)
    const thumbnailMs = performance.now() - thumbnailStarted

    const assets = await command(launched.page, 'culling.list', {
      sessionId: session.id,
      scope: 'all',
    })
    const interactionSamples = []
    let interactionRevision = assets[0].state.revision
    for (let index = 0; index < 20; index++) {
      const interactionStarted = performance.now()
      const update = await command(launched.page, 'culling.update', {
        sessionId: session.id,
        photoId: assets[0].photo.id,
        expectedRevision: interactionRevision,
        patch: { pickState: index % 2 === 0 ? 'picked' : 'unreviewed' },
      })
      interactionSamples.push(performance.now() - interactionStarted)
      interactionRevision = update.states[0].revision
    }
    interactionSamples.sort((left, right) => left - right)
    const interactionP95Ms = interactionSamples[
      Math.min(interactionSamples.length - 1, Math.ceil(interactionSamples.length * 0.95) - 1)
    ]
    const ratingStarted = performance.now()
    await command(launched.page, 'culling.update', {
      sessionId: session.id,
      photoId: assets[0].photo.id,
      expectedRevision: interactionRevision,
      patch: { rating: 1 },
    })
    await command(launched.page, 'culling.flush', { sessionId: session.id })
    const ratingToWrittenMs = performance.now() - ratingStarted
    const longestRendererTaskMs = await launched.page.evaluate(
      () => globalThis.__gatherBenchmarkLongestTask ?? 0,
    )
    const jobsBeforeClose = await command(launched.page, 'jobs.list')
    const failedJobs = jobsBeforeClose.filter(job =>
      ['failed', 'cancelled', 'interrupted'].includes(job.status),
    ).length
    const retriedJobs = jobsBeforeClose.filter(job => job.attemptCount > 1).length
    const firstPid = launched.app.process().pid

    await launched.app.close()
    clearInterval(sample)
    const remainingProcessRssBytes = processTreeRssBytes(firstPid)
    const reopenStarted = performance.now()
    launched = await launch(userData)
    await launched.page.evaluate(id => {
      window.location.hash = `#/sessions/${id}/gallery`
    }, session.id)
    const reopenIndex = await command(launched.page, 'index.scan', {
      sessionId: session.id,
      confirmed: true,
    })
    const reopenedJob = await waitForJob(launched.page, reopenIndex.id)
    const reopenAndIndexMs = performance.now() - reopenStarted
    await launched.app.close()

    return {
      importMs,
      firstWindowMs,
      firstGalleryInteractiveMs,
      reopenAndIndexMs,
      unchangedFilesSkipped: Number(reopenedJob.checkpoint?.result?.skipped ?? 0),
      thumbnailSampleCount: thumbnailPaths.length,
      thumbnailPerSecond: thumbnailPaths.length / (thumbnailMs / 1_000),
      ratingToWrittenMs,
      interactionP95Ms,
      longestRendererTaskMs,
      failedJobs,
      retriedJobs,
      remainingProcessRssBytes,
      peakRssBytes,
      sqliteBytes: (await stat(path.join(userData, 'gather.db'))).size,
    }
  } finally {
    clearInterval(sample)
    await launched.app.close().catch(() => undefined)
    await rm(root, { recursive: true, force: true })
  }
}

const results = {}
for (const size of sizes) {
  results[size] = await benchmark(size)
  process.stdout.write(`${JSON.stringify({ size, result: results[size] })}\n`)
}
process.stdout.write(`${JSON.stringify({
  generatedAt: new Date().toISOString(),
  host: {
    platform: process.platform,
    release: os.release(),
    arch: process.arch,
    cpu: os.cpus()[0]?.model,
    logicalCpuCount: os.cpus().length,
    memoryBytes: os.totalmem(),
    node: process.version,
  },
  onnxEnabled: false,
  gpuProvider: 'not used by this benchmark',
  results,
}, null, 2)}\n`)
