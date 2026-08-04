import { test, expect, _electron as electron, type ElectronApplication } from '@playwright/test'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import path from 'path'
import sharp from 'sharp'
import { exiftool } from 'exiftool-vendored'

let app: ElectronApplication
let userDataDir: string
let photoPath: string
let sessionId: string
const rendererErrors: string[] = []

test.beforeAll(async () => {
  userDataDir = mkdtempSync(path.join(tmpdir(), 'gather-e2e-'))
  photoPath = path.join(userDataDir, 'protocol-photo.jpg')
  await sharp({
    create: {
      width: 320,
      height: 180,
      channels: 3,
      background: '#406080',
    },
  }).jpeg().toFile(photoPath)
  app = await electron.launch({
    args: [
      path.resolve(process.cwd(), 'desktop'),
      `--user-data-dir=${userDataDir}`,
    ],
    cwd: process.cwd(),
    env: {
      ...process.env,
      NODE_ENV: 'production',
    },
  })
  const window = await app.firstWindow()
  window.on('pageerror', error => rendererErrors.push(error.message))
  window.on('console', message => {
    if (message.type() === 'error') rendererErrors.push(message.text())
  })
})

test('imports a photo and renders it through the binary image protocol', async () => {
  const window = await app.firstWindow()
  sessionId = await window.evaluate(async (photo) => {
    const response = await window.gather.sendCommand('session.create', {
      name: 'Protocol smoke test',
      source: 'folder',
      sourcePath: photo.replace(/[/\\][^/\\]+$/, ''),
      filepaths: [photo],
    })
    if (!response.ok) {
      throw new Error(typeof response.error === 'string' ? response.error : response.error.message)
    }
    return (response.data as { id: string }).id
  }, photoPath)

  await window.evaluate(id => {
    window.location.hash = `#/sessions/${id}/gallery`
  }, sessionId)
  const image = window.locator('img').first()
  await expect(image).toBeVisible()
  await expect.poll(() => image.evaluate(element => (element as HTMLImageElement).naturalWidth))
    .toBeGreaterThan(0)
  expect(await image.getAttribute('src')).toMatch(/^gather-image:\/\/thumbnail/)
  if (process.env.GATHER_E2E_SCREENSHOT_PATH) {
    await window.screenshot({
      path: process.env.GATHER_E2E_SCREENSHOT_PATH.replace(/(\.[^.]+)$/, '-gallery$1'),
      fullPage: true,
    })
  }
})

test('renders the supporting workflow pages without visual runtime errors', async () => {
  const window = await app.firstWindow()
  const routes = [
    { route: 'face-kw', marker: '分析', suffix: 'face' },
    { route: 'duplicates', marker: '重复照片检测', suffix: 'duplicates' },
    { route: 'export', marker: '批量导出', suffix: 'export' },
  ]

  for (const { route, marker, suffix } of routes) {
    await window.evaluate(({ id, routeName }) => {
      window.location.hash = `#/sessions/${id}/${routeName}`
    }, { id: sessionId, routeName: route })
    await expect(window.getByText(marker, { exact: true }).first()).toBeVisible()
    await expect(window.getByRole('link', { name: route === 'face-kw'
      ? '人脸'
      : route === 'duplicates'
        ? '重复'
        : '导出' })).toHaveAttribute('aria-current', 'page')
    if (process.env.GATHER_E2E_SCREENSHOT_PATH) {
      await window.screenshot({
        path: process.env.GATHER_E2E_SCREENSHOT_PATH.replace(/(\.[^.]+)$/, `-${suffix}$1`),
        fullPage: true,
      })
    }
  }

  await window.evaluate(() => {
    window.location.hash = '#/library'
  })
  await expect(window.getByRole('heading', { name: '全局图库' })).toBeVisible()
  await expect(window.getByText('RAW / JPEG 关联')).toBeVisible()

  await window.evaluate(() => {
    window.location.hash = '#/jobs'
  })
  await expect(window.getByRole('heading', { name: '任务中心' })).toBeVisible()
  await expect(window.getByRole('button', { name: '清理已完成' })).toBeVisible()

  expect(rendererErrors).toEqual([])
})

test('shows the model-install guidance card on the face analyze step without models', async () => {
  const window = await app.firstWindow()
  await window.evaluate(id => {
    window.location.hash = `#/sessions/${id}/face-kw`
  }, sessionId)
  await expect(window.getByText(/人脸模型未安装/)).toBeVisible()
  await expect(window.getByRole('button', { name: '打开设置' })).toBeVisible()
  await expect(window.getByText(/开始分析/)).toBeVisible()
  expect(rendererErrors).toEqual([])
})

test('supports sequential and global similarity grouping modes', async () => {
  const window = await app.firstWindow()
  await window.evaluate(async (id) => {
    const response = await window.gather.sendCommand('sim.analyze', {
      sessionId: id,
      threshold: 10,
      minGroupSize: 2,
      groupingMode: 'sequential',
    })
    if (!response.ok) {
      throw new Error(typeof response.error === 'string' ? response.error : response.error.message)
    }
  }, sessionId)
  const sequential = await window.evaluate(async (id) => {
    const response = await window.gather.sendCommand('sim.result', { sessionId: id })
    if (!response.ok) {
      throw new Error(typeof response.error === 'string' ? response.error : response.error.message)
    }
    return response.data as { stats: { groupingMode: string } }
  }, sessionId)
  expect(sequential.stats.groupingMode).toBe('sequential')

  const global = await window.evaluate(async (id) => {
    const response = await window.gather.sendCommand('sim.recluster', {
      sessionId: id,
      threshold: 10,
      minGroupSize: 2,
      groupingMode: 'global',
    })
    if (!response.ok) {
      throw new Error(typeof response.error === 'string' ? response.error : response.error.message)
    }
    return response.data as { stats: { groupingMode: string } }
  }, sessionId)
  expect(global.stats.groupingMode).toBe('global')

  await window.evaluate(id => {
    window.location.hash = `#/sessions/${id}/similarity`
  }, sessionId)
  await expect(window.getByRole('button', { name: /顺序分组/ })).toBeVisible()
  await expect(window.getByRole('button', { name: /全局分组/ })).toBeVisible()
  if (process.env.GATHER_E2E_SCREENSHOT_PATH) {
    await window.screenshot({
      path: process.env.GATHER_E2E_SCREENSHOT_PATH.replace(/(\.[^.]+)$/, '-similarity$1'),
      fullPage: true,
    })
  }
})

test('rates and labels without a similarity group, then writes a Capture One XMP sidecar', async () => {
  const window = await app.firstWindow()
  const xmpPath = photoPath.replace(/\.[^.]+$/, '.xmp')
  writeFileSync(xmpPath, `<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Gather E2E">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:vendor="https://example.invalid/vendor/1.0/">
      <vendor:Preserved>do-not-remove</vendor:Preserved>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>`)
  const assets = await window.evaluate(async (id) => {
    const response = await window.gather.sendCommand('culling.list', {
      sessionId: id,
      scope: 'all',
    })
    if (!response.ok) {
      throw new Error(typeof response.error === 'string' ? response.error : response.error.message)
    }
    return response.data as Array<{
      photo: { id: string }
      state: { revision: number }
    }>
  }, sessionId)
  expect(assets).toHaveLength(1)

  const first = await window.evaluate(async ({ id, photoId, revision }) => {
    const response = await window.gather.sendCommand('culling.update', {
      sessionId: id,
      photoId,
      expectedRevision: revision,
      patch: { rating: 5 },
    })
    if (!response.ok) {
      throw new Error(typeof response.error === 'string' ? response.error : response.error.message)
    }
    return response.data as { states: Array<{ revision: number }> }
  }, {
    id: sessionId,
    photoId: assets[0].photo.id,
    revision: assets[0].state.revision,
  })

  await window.evaluate(async ({ id, photoId, revision }) => {
    const update = await window.gather.sendCommand('culling.update', {
      sessionId: id,
      photoId,
      expectedRevision: revision,
      patch: { colorLabel: 'Green', pickState: 'picked' },
    })
    if (!update.ok) {
      throw new Error(typeof update.error === 'string' ? update.error : update.error.message)
    }
    const flush = await window.gather.sendCommand('culling.flush', { sessionId: id })
    if (!flush.ok) {
      throw new Error(typeof flush.error === 'string' ? flush.error : flush.error.message)
    }
    const metadata = await window.gather.sendCommand('metadata.set', {
      photoId,
      tags: { keywords: ['人物|张三', '婚礼'] },
      confirmed: true,
    })
    if (!metadata.ok) {
      throw new Error(typeof metadata.error === 'string' ? metadata.error : metadata.error.message)
    }
    const keywordFlush = await window.gather.sendCommand('culling.flush', { sessionId: id })
    if (!keywordFlush.ok) {
      throw new Error(typeof keywordFlush.error === 'string'
        ? keywordFlush.error
        : keywordFlush.error.message)
    }
  }, {
    id: sessionId,
    photoId: assets[0].photo.id,
    revision: first.states[0].revision,
  })

  expect(existsSync(xmpPath)).toBe(true)
  const xmp = readFileSync(xmpPath, 'utf8')
  expect(xmp).toContain('xmp:Rating')
  expect(xmp).toContain('>5</xmp:Rating>')
  expect(xmp).toContain('xmp:Label')
  expect(xmp).toContain('>Green</xmp:Label>')
  expect(xmp).toContain('photoshop:Urgency')
  expect(xmp).toContain('vendor:Preserved')
  expect(xmp).toContain('do-not-remove')
  const parsedXmp = await exiftool.read(xmpPath, ['Rating', 'Label', 'Urgency', 'Subject'])
  expect(Number(parsedXmp.Rating)).toBe(5)
  expect(parsedXmp.Label).toBe('Green')
  expect(Number(parsedXmp.Urgency)).toBe(2)
  expect(parsedXmp.Subject).toEqual(expect.arrayContaining(['人物|张三', '婚礼']))

  await window.evaluate(id => {
    window.location.hash = `#/sessions/${id}/culling`
  }, sessionId)
  await expect(window.getByText('自动前进')).toBeVisible()
  await expect(window.getByRole('button', { name: '2 图' })).toBeVisible()
  await expect(window.getByRole('button', { name: '保留 P' })).toBeVisible()
  expect((await window.locator('nav a').allTextContents()).slice(-6)).toEqual([
    '浏览',
    '相似度',
    '人脸',
    '重复',
    '挑片',
    '导出',
  ])
  if (process.env.GATHER_E2E_SCREENSHOT_PATH) {
    await window.screenshot({
      path: process.env.GATHER_E2E_SCREENSHOT_PATH,
      fullPage: true,
    })
  }
  expect(rendererErrors).toEqual([])
})

test('keeps a shared XMP outbox visible from every importing session', async () => {
  const window = await app.firstWindow()
  const result = await window.evaluate(async ({ firstSessionId, filepath }) => {
    const created = await window.gather.sendCommand('session.create', {
      name: 'Shared sidecar session',
      source: 'folder',
      sourcePath: filepath.replace(/[/\\][^/\\]+$/, ''),
      filepaths: [filepath],
    })
    if (!created.ok) throw new Error(String(created.error))
    const secondSessionId = (created.data as { id: string }).id
    const assets = await window.gather.sendCommand('culling.list', {
      sessionId: secondSessionId,
      scope: 'all',
    })
    if (!assets.ok) throw new Error(String(assets.error))
    const asset = (assets.data as Array<{
      photo: { id: string }
      state: { revision: number }
    }>)[0]
    const updated = await window.gather.sendCommand('culling.update', {
      sessionId: secondSessionId,
      photoId: asset.photo.id,
      expectedRevision: asset.state.revision,
      patch: { rating: 5, colorLabel: 'Green' },
    })
    if (!updated.ok) throw new Error(String(updated.error))
    const flushed = await window.gather.sendCommand('culling.flush', {
      sessionId: secondSessionId,
    })
    if (!flushed.ok) throw new Error(String(flushed.error))
    const firstSummary = await window.gather.sendCommand('culling.sync_status', {
      sessionId: firstSessionId,
    })
    const secondSummary = await window.gather.sendCommand('culling.sync_status', {
      sessionId: secondSessionId,
    })
    if (!firstSummary.ok || !secondSummary.ok) throw new Error('Unable to read sync summaries')
    return {
      firstItems: (firstSummary.data as { items: unknown[] }).items.length,
      secondItems: (secondSummary.data as { items: unknown[] }).items.length,
    }
  }, { firstSessionId: sessionId, filepath: photoPath })

  expect(result).toEqual({ firstItems: 1, secondItems: 1 })
})

test('restores culling state and XMP after an application restart', async () => {
  await app.close()
  app = await electron.launch({
    args: [
      path.resolve(process.cwd(), 'desktop'),
      `--user-data-dir=${userDataDir}`,
    ],
    cwd: process.cwd(),
    env: {
      ...process.env,
      NODE_ENV: 'production',
    },
  })
  const window = await app.firstWindow()
  const restored = await window.evaluate(async (id) => {
    const response = await window.gather.sendCommand('culling.list', {
      sessionId: id,
      scope: 'all',
    })
    if (!response.ok) {
      throw new Error(typeof response.error === 'string' ? response.error : response.error.message)
    }
    return response.data as Array<{
      state: { rating: number; colorLabel: string; pickState: string }
    }>
  }, sessionId)

  expect(restored).toHaveLength(1)
  expect(restored[0].state).toMatchObject({
    rating: 5,
    colorLabel: 'Green',
    pickState: 'picked',
  })
  const xmpPath = photoPath.replace(/\.[^.]+$/, '.xmp')
  expect(readFileSync(xmpPath, 'utf8')).toContain('>5</xmp:Rating>')
  expect(readFileSync(xmpPath, 'utf8')).toContain('>Green</xmp:Label>')
})

test.afterAll(async () => {
  await app?.close()
  await exiftool.end()
  rmSync(userDataDir, { recursive: true, force: true })
})

test('launches the production renderer and exposes the core workspace entry', async () => {
  const window = await app.firstWindow()
  await window.evaluate(() => { window.location.hash = '#/' })
  await expect(window).toHaveTitle(/Gather/)
  await expect(window.getByText('工作台', { exact: true })).toBeVisible()
  await expect(window.getByRole('button', { name: '新建工作区' })).toBeVisible()
  if (process.env.GATHER_E2E_SCREENSHOT_PATH) {
    await window.screenshot({
      path: process.env.GATHER_E2E_SCREENSHOT_PATH.replace(/(\.[^.]+)$/, '-dashboard$1'),
      fullPage: true,
    })
  }

  await window.evaluate(() => { window.location.hash = '#/settings' })
  await expect(window.getByRole('heading', { name: '设置', exact: true }).first()).toBeVisible()
  if (process.env.GATHER_E2E_SCREENSHOT_PATH) {
    await window.screenshot({
      path: process.env.GATHER_E2E_SCREENSHOT_PATH.replace(/(\.[^.]+)$/, '-settings$1'),
      fullPage: true,
    })
  }
  expect(rendererErrors).toEqual([])
})

test('keeps navigation and culling controls usable in a compact window', async () => {
  const window = await app.firstWindow()
  await window.setViewportSize({ width: 700, height: 760 })
  await window.evaluate(id => {
    window.location.hash = `#/sessions/${id}/culling`
  }, sessionId)
  await expect(window.getByText('自动前进')).toBeVisible()
  await expect(window.getByRole('navigation', { name: '主导航' })).toHaveCount(0)
  await expect(window.getByRole('link', { name: '返回工作台' })).toBeVisible()
  await expect(window.getByRole('button', { name: '保留 P' })).toBeVisible()
  if (process.env.GATHER_E2E_SCREENSHOT_PATH) {
    await window.screenshot({
      path: process.env.GATHER_E2E_SCREENSHOT_PATH.replace(/(\.[^.]+)$/, '-compact$1'),
      fullPage: true,
    })
  }
  expect(rendererErrors).toEqual([])
})
