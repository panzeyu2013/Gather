import { $, $$, esc, on, setText } from './dom'

describe('$', () => {
  beforeEach(() => {
    document.body.innerHTML = '<div id="test"><span class="child">A</span><span class="child">B</span></div>'
  })

  it('returns element matching selector', () => {
    const el = $('#test')
    expect(el).toBeInstanceOf(HTMLDivElement)
    expect(el!.id).toBe('test')
  })

  it('returns null for non-existent selector', () => {
    expect($('#nonexistent')).toBeNull()
  })

  it('searches within given parent', () => {
    const parent = $('#test')!
    const span = $('.child', parent)
    expect(span).toBeInstanceOf(HTMLSpanElement)
    expect(span!.textContent).toBe('A')
  })
})

describe('$$', () => {
  beforeEach(() => {
    document.body.innerHTML = '<ul><li class="item">1</li><li class="item">2</li><li>3</li></ul>'
  })

  it('returns NodeListOf matching elements', () => {
    const items = $$('.item')
    expect(items).toHaveLength(2)
    expect(items[0].textContent).toBe('1')
    expect(items[1].textContent).toBe('2')
  })

  it('returns empty NodeList when no matches', () => {
    expect($$('.nonexistent')).toHaveLength(0)
  })
})

describe('esc', () => {
  it('escapes HTML entities', () => {
    expect(esc('<script>alert(1)</script>')).toBe('&lt;script&gt;alert(1)&lt;/script&gt;')
  })

  it('escapes ampersands', () => {
    expect(esc('a & b')).toBe('a &amp; b')
  })

  it('returns empty string for empty input via String coercion', () => {
    expect(esc('')).toBe('')
  })

  it('handles plain text without escaping', () => {
    expect(esc('Hello')).toBe('Hello')
  })
})

describe('on', () => {
  beforeEach(() => {
    document.body.innerHTML = '<div id="container"><button class="btn" data-id="1">Click</button></div>'
  })

  it('binds delegated event handler', () => {
    const handler = jest.fn()
    const container = document.getElementById('container')!
    const cleanup = on(container, 'click', '.btn', handler)

    document.querySelector<HTMLButtonElement>('.btn')!.click()
    expect(handler).toHaveBeenCalledTimes(1)

    cleanup()
  })

  it('returns cleanup function that removes listener', () => {
    const handler = jest.fn()
    const container = document.getElementById('container')!
    const cleanup = on(container, 'click', '.btn', handler)

    cleanup()
    document.querySelector<HTMLButtonElement>('.btn')!.click()
    expect(handler).not.toHaveBeenCalled()
  })

  it('does not trigger handler for non-matching elements', () => {
    const handler = jest.fn()
    const container = document.getElementById('container')!
    on(container, 'click', '.nonexistent', handler)

    document.querySelector<HTMLButtonElement>('.btn')!.click()
    expect(handler).not.toHaveBeenCalled()
  })

  it('passes the matching element and event to handler', () => {
    const handler = jest.fn()
    const container = document.getElementById('container')!
    on(container, 'click', '.btn', handler)

    const btn = document.querySelector<HTMLButtonElement>('.btn')!
    btn.click()
    expect(handler).toHaveBeenCalledWith(btn, expect.any(MouseEvent))
  })
})

describe('setText', () => {
  beforeEach(() => {
    document.body.innerHTML = '<div id="status"></div><span class="count">0</span>'
  })

  it('sets textContent by id', () => {
    setText('status', 'active')
    expect(document.getElementById('status')!.textContent).toBe('active')
  })

  it('sets textContent by selector fallback', () => {
    setText('.count', 5)
    expect(document.querySelector('.count')!.textContent).toBe('5')
  })

  it('does not throw for missing elements', () => {
    expect(() => setText('#nonexistent', 'value')).not.toThrow()
  })
})
