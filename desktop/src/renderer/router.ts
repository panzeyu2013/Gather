// src/renderer/router.ts
// 路由核心 — 被 app.ts 和所有 page 模块引用，打破循环依赖

export type PageName = 'dashboard' | 'similarity' | 'face-kw'

let currentCleanup: (() => void) | null = null
let navigateFn: ((page: PageName, sid?: string) => void) | null = null

export function setNavigate(fn: (page: PageName, sid?: string) => void): void {
  navigateFn = fn
}

export function navigate(page: PageName, sid?: string): void {
  navigateFn?.(page, sid)
}

export function registerCleanup(fn: () => void): void {
  currentCleanup = fn
}

export function runCleanup(): void {
  if (!currentCleanup) return
  try {
    currentCleanup()
  } finally {
    currentCleanup = null
  }
}
