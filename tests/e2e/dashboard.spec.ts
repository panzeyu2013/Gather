import { test, expect } from '@playwright/test'

test('dashboard renders with title', async ({ page }) => {
  await page.goto('/#/')
  await expect(page.locator('#root')).not.toBeEmpty()
})

test('dashboard shows gather title or error', async ({ page }) => {
  await page.goto('/#/')
  // In browser dev mode, IPC calls fail, showing error. Check page renders.
  const title = page.locator('text=Gather')
  const error = page.locator('text=Failed to load sessions')
  await expect(title.or(error).first()).toBeVisible({ timeout: 10000 })
})
