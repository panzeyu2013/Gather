// Capture One 导入预检门控（design_improvements.md 2.3.4 / 2.3.5 P1）。
// 纯函数：c1:health 结果 → 四格检查 + 是否放行 + 引导文案。
// 门控决策：C1 导入路径要求四层全部通过
// （reachable + appRunning + automationAuthorized + documentOpen），
// 任一失败即不调用 getSelectedPhotos，改为内联展示失败与引导。

import { t as defaultT, type TranslationKey, type TypedTFunction } from '../locales'

export type C1CheckKey =
  | 'reachable'
  | 'appRunning'
  | 'documentOpen'
  | 'automationAuthorized'
  | 'timeout'

/** 预检只依赖四个布尔位 + 超时标记；完整 C1Health（preload 形状）结构兼容此 Lite 形状。 */
export interface C1HealthLite {
  reachable: boolean
  appRunning: boolean
  documentOpen: boolean
  automationAuthorized: boolean
  /** 探针超时（Apple Events -1712 / 探针被杀）：此时不得声称自动化已授权。 */
  timedOut?: boolean
}

export interface C1PreflightCheck {
  key: C1CheckKey
  label: string
  passed: boolean
}

export interface C1PreflightResult {
  passed: boolean
  checks: C1PreflightCheck[]
  failedKeys: C1CheckKey[]
}

const ALL_FAILED: C1HealthLite = {
  reachable: false,
  appRunning: false,
  documentOpen: false,
  automationAuthorized: false,
}

const CHECK_LABEL_KEYS: Record<C1CheckKey, TranslationKey> = {
  reachable: 'c1.preflight.reachable',
  appRunning: 'c1.preflight.appRunning',
  documentOpen: 'c1.preflight.documentOpen',
  automationAuthorized: 'c1.preflight.automationAuthorized',
  timeout: 'c1.preflight.timeout',
}

const CHECK_GUIDANCE_KEYS: Record<C1CheckKey, TranslationKey> = {
  reachable: 'c1.preflight.guidance.reachable',
  appRunning: 'c1.preflight.guidance.appRunning',
  documentOpen: 'c1.preflight.guidance.documentOpen',
  automationAuthorized: 'c1.preflight.guidance.automationAuthorized',
  timeout: 'c1.preflight.guidance.timeout',
}

export function evaluateC1Preflight(
  health: C1HealthLite,
  translator: TypedTFunction = defaultT,
): C1PreflightResult {
  // The timeout check only appears when the probe actually timed out; a
  // healthy run keeps the familiar four-check list.
  const keys: C1CheckKey[] = health.timedOut
    ? ['reachable', 'appRunning', 'documentOpen', 'automationAuthorized', 'timeout']
    : ['reachable', 'appRunning', 'documentOpen', 'automationAuthorized']
  const checks: C1PreflightCheck[] = keys.map(key => ({
    key,
    label: translator(CHECK_LABEL_KEYS[key]),
    passed: key === 'timeout' ? !health.timedOut : health[key],
  }))
  const failedKeys = checks.filter(check => !check.passed).map(check => check.key)
  return { passed: failedKeys.length === 0, checks, failedKeys }
}

/** 未通过时的内联引导文案；全部通过返回 null。 */
export function c1PreflightGuidance(
  failedKeys: C1CheckKey[],
  translator: TypedTFunction = defaultT,
): string | null {
  if (failedKeys.length === 0) return null
  // Timeout first: a hung app or a pending TCC prompt must not be guided to
  // "open a document" or "grant automation" — retry instead.
  if (failedKeys.includes('timeout')) {
    return translator(CHECK_GUIDANCE_KEYS.timeout)
  }
  if (failedKeys.includes('reachable')) {
    return translator(CHECK_GUIDANCE_KEYS.reachable)
  }
  // -1743 / not authorized：TCC Automation 权限被拒，引导到系统设置授权。
  if (failedKeys.includes('automationAuthorized')) {
    return translator(CHECK_GUIDANCE_KEYS.automationAuthorized)
  }
  if (failedKeys.includes('appRunning')) {
    return translator(CHECK_GUIDANCE_KEYS.appRunning)
  }
  if (failedKeys.includes('documentOpen')) {
    return translator(CHECK_GUIDANCE_KEYS.documentOpen)
  }
  return null
}

/** 预检调用整体失败（IPC 异常等）时的兜底结果。 */
export function failedC1Preflight(translator?: TypedTFunction): C1PreflightResult {
  return evaluateC1Preflight(ALL_FAILED, translator)
}
