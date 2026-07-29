import { test, expect, _electron as electron, type ElectronApplication } from '@playwright/test'
import { mkdtempSync, rmSync } from 'fs'
import { tmpdir } from 'os'
import path from 'path'
import sharp from 'sharp'

let app: ElectronApplication
let userDataDir: string
let photoPath: string
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
  const sessionId = await window.evaluate(async (photo) => {
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
})

test.afterAll(async () => {
  await app?.close()
  rmSync(userDataDir, { recursive: true, force: true })
})

test('launches the production renderer and exposes the core workspace entry', async () => {
  const window = await app.firstWindow()
  await window.evaluate(() => { window.location.hash = '#/' })
  await expect(window).toHaveTitle(/Gather/)
  await expect(window.getByText('工作台', { exact: true })).toBeVisible()
  await expect(window.getByRole('button', { name: '新建工作区' })).toBeVisible()
  expect(rendererErrors).toEqual([])
})
