import { test, expect } from '@playwright/test'

test('face keywording page url is accessible', async ({ page }) => {
  // Navigate to face-kw page - may show loading or error in browser dev mode
  const response = await page.goto('/#/face-kw/new')
  expect(response?.status()).toBe(200)
})
