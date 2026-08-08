// src/main/services/capture-one/errors.ts
// Shared Capture One error classifier (design_improvements.md 4.4.2).
//
// One pure classifier used by both the osascript bridge (capture-one.ts) and
// the health probe (c1-health.ts), so the recognition regexes cannot drift
// apart. The classifier recognizes four kinds:
//   denied     — TCC Automation denial (Apple Events error -1743 / "not authorized")
//   noDocument — Capture One reports no open document
//   timeout    — Apple Events timed out (-1712) or the probe itself was killed
//   generic    — anything else, surfaced as a generic script failure
//
// Timeout is checked first: a hung app must never be mistaken for a denial or
// a missing document.

export type CaptureOneErrorKind = 'denied' | 'noDocument' | 'timeout' | 'generic'

export function classifyCaptureOneError(raw: string): CaptureOneErrorKind {
  const lower = raw.toLowerCase()
  if (/timed out|-1712|etimedout/i.test(lower)) return 'timeout'
  if (/-1743|not authorized/i.test(lower)) return 'denied'
  if (/no document is open|doesn't understand.*document|not open any document/i.test(lower)) {
    return 'noDocument'
  }
  return 'generic'
}

export function isAutomationDeniedMessage(message: string): boolean {
  return classifyCaptureOneError(message) === 'denied'
}

export function isNoDocumentMessage(message: string): boolean {
  return classifyCaptureOneError(message) === 'noDocument'
}

export function isTimeoutMessage(message: string): boolean {
  return classifyCaptureOneError(message) === 'timeout'
}
