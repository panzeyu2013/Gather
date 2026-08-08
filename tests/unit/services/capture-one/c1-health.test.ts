import { describe, expect, it } from 'vitest'
import {
  classifyCaptureOneError,
  isAutomationDeniedMessage,
  isNoDocumentMessage,
  isTimeoutMessage,
} from '../../../../desktop/src/main/services/capture-one/errors'
import {
  countVariantOutputLines,
  parseProcessNames,
} from '../../../../desktop/src/main/services/capture-one/c1-health'

describe('classifyCaptureOneError — shared classifier matrix (denied / no-document / timeout / generic)', () => {
  it('classifies the -1743 / not authorized denial as denied', () => {
    const denied = [
      'Command failed: osascript: execution error: Not authorized to send Apple events to System Events. (-1743)',
      'osascript: execution error: Capture One Pro got an error: not authorized. (-1743)',
      'osascript: execution error: not authorized to send Apple events',
    ]
    for (const message of denied) {
      expect(classifyCaptureOneError(message)).toBe('denied')
    }
  })

  it('classifies no-document variants as noDocument', () => {
    const noDocument = [
      'osascript: execution error: Capture One Pro got an error: No document is open. (-1728)',
      'osascript: execution error: Capture One Pro got an error: Not open any document. (-1728)',
      'osascript: execution error: Capture One Pro got an error: Capture One doesn\'t understand "reload" of document 1. (-1708)',
    ]
    for (const message of noDocument) {
      expect(classifyCaptureOneError(message)).toBe('noDocument')
    }
  })

  it('classifies Apple Events timeouts and probe kills as timeout', () => {
    const timeouts = [
      'osascript: execution error: Apple Events timed out. (-1712)',
      'osascript: execution error: Capture One Pro got an error: AppleEvent timed out. (-1712)',
      'spawn osascript ETIMEDOUT',
      'Command failed: osascript: execution error: timed out waiting for the application to respond',
    ]
    for (const message of timeouts) {
      expect(classifyCaptureOneError(message)).toBe('timeout')
    }
  })

  it('classifies unrelated failures as generic', () => {
    const generic = [
      '',
      'osascript: execution error: syntax error: Expected end of line but found identifier. (-2741)',
      'osascript: execution error: Capture One Pro got an error: Can\'t get current document. (-1728)',
      'unknown application "Photoshop"',
      'Some random message',
    ]
    for (const message of generic) {
      expect(classifyCaptureOneError(message)).toBe('generic')
    }
  })

  it('keeps the derived predicates in sync with the classifier', () => {
    expect(isAutomationDeniedMessage(
      'osascript: execution error: Capture One Pro got an error: not authorized. (-1743)',
    )).toBe(true)
    expect(isAutomationDeniedMessage(
      'osascript: execution error: Apple Events timed out. (-1712)',
    )).toBe(false)
    expect(isNoDocumentMessage('No document is open')).toBe(true)
    expect(isTimeoutMessage('Apple Events timed out. (-1712)')).toBe(true)
    expect(isTimeoutMessage('no document is open')).toBe(false)
  })
})

describe('parseProcessNames', () => {
  it('parses the System Events process list format', () => {
    expect(parseProcessNames('Capture One Pro')).toEqual(['Capture One Pro'])
    expect(parseProcessNames('Capture One Pro, Capture One')).toEqual(['Capture One Pro', 'Capture One'])
    expect(parseProcessNames('')).toEqual([])
  })
})

describe('countVariantOutputLines', () => {
  it('counts non-empty lines from the selected-variants script output', () => {
    expect(countVariantOutputLines('/a/NEF\n/b/NEF\n')).toBe(2)
    expect(countVariantOutputLines('\n  \n')).toBe(0)
    expect(countVariantOutputLines('')).toBe(0)
  })
})
