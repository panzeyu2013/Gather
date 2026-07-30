import { test, expect, _electron as electron, type ElectronApplication } from '@playwright/test'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'fs'
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
    if (process.env.GATHER_E2E_SCREENSHOT_PATH) {
      await window.screenshot({
        path: process.env.GATHER_E2E_SCREENSHOT_PATH.replace(/(\.[^.]+)$/, `-${suffix}$1`),
        fullPage: true,
      })
    }
  }

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
  }, {
    id: sessionId,
    photoId: assets[0].photo.id,
    revision: first.states[0].revision,
  })

  const xmpPath = photoPath.replace(/\.[^.]+$/, '.xmp')
  expect(existsSync(xmpPath)).toBe(true)
  const xmp = readFileSync(xmpPath, 'utf8')
  expect(xmp).toContain('xmp:Rating')
  expect(xmp).toContain('>5</xmp:Rating>')
  expect(xmp).toContain('xmp:Label')
  expect(xmp).toContain('>Green</xmp:Label>')
  expect(xmp).toContain('photoshop:Urgency')
  const parsedXmp = await exiftool.read(xmpPath, ['Rating', 'Label', 'Urgency'])
  expect(Number(parsedXmp.Rating)).toBe(5)
  expect(parsedXmp.Label).toBe('Green')
  expect(Number(parsedXmp.Urgency)).toBe(2)

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
