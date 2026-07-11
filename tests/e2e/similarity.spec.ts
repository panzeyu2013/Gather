import { test, expect } from '@playwright/test'

test('similarity page shows analysis panel', async ({ page }) => {
  await page.goto('/#/similarity/new')
  await expect(page.locator('text=Analysis Controls')).toBeVisible()
  await expect(page.locator('text=Analyze')).toBeVisible()
})

test('similarity page renders with content', async ({ page }) => {
  await page.goto('/#/similarity/new')
  await expect(page.locator('#root')).not.toBeEmpty()
})
