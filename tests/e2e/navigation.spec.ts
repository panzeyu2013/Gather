import { test, expect } from '@playwright/test'

test('sidebar navigation switches between pages', async ({ page }) => {
  await page.goto('/#/')

  await expect(page.locator('text=Gather').first()).toBeVisible()

  await page.locator('text=Similarity').click()
  await expect(page).toHaveURL(/\/similarity/)

  await page.locator('text=Dashboard').click()
  await expect(page).toHaveURL(/\/(#\/)?$/)

  await page.locator('text=Face Keywording').click()
  await expect(page).toHaveURL(/\/face-kw/)
})
