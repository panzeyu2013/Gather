import { describe, expect, it } from 'vitest'
import {
  c1PreflightGuidance,
  evaluateC1Preflight,
  failedC1Preflight,
} from '../../../desktop/src/renderer/utils/c1-preflight'
import type { TypedTFunction } from '../../../desktop/src/renderer/locales'

/** zh-CN copy snapshot so the pure helpers stay regression-testable. */
const zh: TypedTFunction = ((key: any) => {
  const map: Record<string, string> = {
    'c1.preflight.reachable': '可连接 Capture One（AppleScript）',
    'c1.preflight.appRunning': 'Capture One 正在运行',
    'c1.preflight.documentOpen': 'Capture One 已打开文档',
    'c1.preflight.automationAuthorized': '自动化权限已授权',
    'c1.preflight.guidance.reachable': '无法通过 AppleScript 访问 Capture One。请确认系统环境正常，然后重新检查。',
    'c1.preflight.guidance.automationAuthorized': '自动化权限未授权：请在 系统设置 → 隐私与安全性 → 自动化 中允许 Gather 控制 Capture One，然后重新检查。',
    'c1.preflight.guidance.appRunning': '未检测到 Capture One 正在运行。请先启动 Capture One，然后重新检查。',
    'c1.preflight.guidance.documentOpen': 'Capture One 未打开任何文档。请先打开一个目录（Document），然后重新检查。',
    'c1.preflight.timeout': '检测超时',
    'c1.preflight.guidance.timeout': '检测超时，请重试',
  }
  const keyName = typeof key === 'string' ? key : key[0]
  return map[keyName] ?? keyName
}) as TypedTFunction

function health(overrides: Partial<{
  reachable: boolean
  appRunning: boolean
  documentOpen: boolean
  automationAuthorized: boolean
  timedOut: boolean
}> = {}) {
  return {
    reachable: true,
    appRunning: true,
    documentOpen: true,
    automationAuthorized: true,
    ...overrides,
  }
}

describe('evaluateC1Preflight — four-check gating (doc 2.3.4/2.3.5)', () => {
  it('all four checks passing means the C1 import path may proceed', () => {
    const result = evaluateC1Preflight(health(), zh)
    expect(result.passed).toBe(true)
    expect(result.failedKeys).toEqual([])
    expect(result.checks).toHaveLength(4)
    expect(result.checks.every(check => check.passed)).toBe(true)
  })

  it('any single failure blocks the import and is reported by key', () => {
    const cases: Array<Partial<Parameters<typeof health>[0]>> = [
      { reachable: false },
      { appRunning: false },
      { documentOpen: false },
      { automationAuthorized: false },
    ]
    for (const override of cases) {
      const result = evaluateC1Preflight(health(override), zh)
      expect(result.passed).toBe(false)
      const failedKey = Object.keys(override)[0]
      expect(result.failedKeys).toEqual([failedKey])
      expect(result.checks.find(check => check.key === failedKey)?.passed).toBe(false)
    }
  })

  it('labels are present for all four checks', () => {
    const result = evaluateC1Preflight(health(), zh)
    const labels = result.checks.map(check => check.label)
    expect(labels).toContain('可连接 Capture One（AppleScript）')
    expect(labels).toContain('Capture One 正在运行')
    expect(labels).toContain('Capture One 已打开文档')
    expect(labels).toContain('自动化权限已授权')
  })

  it('multiple failures are collected together', () => {
    const result = evaluateC1Preflight(health({ appRunning: false, documentOpen: false }), zh)
    expect(result.passed).toBe(false)
    expect(result.failedKeys.sort()).toEqual(['appRunning', 'documentOpen'])
  })

  it('failedC1Preflight is the conservative fallback (everything failed)', () => {
    const result = failedC1Preflight(zh)
    expect(result.passed).toBe(false)
    expect(result.failedKeys).toHaveLength(4)
  })

  it('a probe timeout fails the gate with a dedicated timeout check', () => {
    const result = evaluateC1Preflight(health({ timedOut: true }), zh)
    expect(result.passed).toBe(false)
    expect(result.failedKeys).toContain('timeout')
    const timeoutCheck = result.checks.find(check => check.key === 'timeout')
    expect(timeoutCheck?.passed).toBe(false)
  })

  it('no timeout means the check list stays the familiar four and nothing fails on timeout', () => {
    const result = evaluateC1Preflight(health(), zh)
    expect(result.checks).toHaveLength(4)
    expect(result.checks.some(check => check.key === 'timeout')).toBe(false)
    expect(result.failedKeys).not.toContain('timeout')
  })
})

describe('c1PreflightGuidance — inline guidance per failed check', () => {
  it('automation denial (-1743) points to 系统设置 → 隐私与安全性 → 自动化', () => {
    const guidance = c1PreflightGuidance(['automationAuthorized'], zh)
    expect(guidance).toContain('系统设置')
    expect(guidance).toContain('隐私与安全性')
    expect(guidance).toContain('自动化')
  })

  it('not running asks to start Capture One', () => {
    expect(c1PreflightGuidance(['appRunning'], zh)).toContain('启动 Capture One')
  })

  it('no document asks to open a document', () => {
    expect(c1PreflightGuidance(['documentOpen'], zh)).toContain('打开一个目录')
  })

  it('unreachable takes precedence over TCC guidance (system-level failure)', () => {
    const guidance = c1PreflightGuidance(['reachable', 'appRunning', 'automationAuthorized'], zh)
    expect(guidance).toContain('AppleScript')
    expect(guidance).not.toContain('隐私与安全性')
  })

  it('all checks passing yields no guidance', () => {
    expect(c1PreflightGuidance([], zh)).toBeNull()
  })

  it('a timeout outranks every other guidance: retry instead of actionable steps', () => {
    const guidance = c1PreflightGuidance(['timeout', 'automationAuthorized', 'documentOpen'], zh)
    expect(guidance).toContain('检测超时')
    expect(guidance).not.toContain('隐私与安全性')
    expect(guidance).not.toContain('打开一个目录')
  })
})
