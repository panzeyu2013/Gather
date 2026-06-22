import { toast, toastWithAction, type ToastAction } from './toast'

describe('toast', () => {
  beforeEach(() => {
    document.body.innerHTML = ''
    jest.useFakeTimers()
  })

  afterEach(() => {
    jest.useRealTimers()
  })

  it('creates a toast container and appends toast element', () => {
    toast('Hello world')

    const container = document.querySelector('.toast-container')
    expect(container).not.toBeNull()
    expect(container!.children).toHaveLength(1)
    expect(container!.children[0].textContent).toContain('Hello world')
  })

  it('sets role and aria attributes on toast element', () => {
    toast('Test message')

    const el = document.querySelector('.toast')
    expect(el!.getAttribute('role')).toBe('alert')
    expect(el!.getAttribute('aria-live')).toBe('polite')
    expect(el!.getAttribute('aria-atomic')).toBe('true')
  })

  it('uses assertive aria-live for error type', () => {
    toast('Error message', 'error')

    const el = document.querySelector('.toast')
    expect(el!.getAttribute('aria-live')).toBe('assertive')
  })

  it('applies type class to toast element', () => {
    toast('Success', 'success')
    expect(document.querySelector('.toast--success')).not.toBeNull()

    toast('Warning', 'warning')
    expect(document.querySelector('.toast--warning')).not.toBeNull()

    toast('Info', 'info')
    expect(document.querySelector('.toast--info')).not.toBeNull()
  })

  it('defaults error type duration to 8000ms', () => {
    toast('Error', 'error')
    const el = document.querySelector('.toast')!

    jest.advanceTimersByTime(7999)
    expect(el.classList.contains('toast--out')).toBe(false)

    jest.advanceTimersByTime(1)
    expect(el.classList.contains('toast--out')).toBe(true)
  })

  it('defaults non-error duration to 3500ms', () => {
    toast('Info', 'info')
    const el = document.querySelector('.toast')!

    jest.advanceTimersByTime(3499)
    expect(el.classList.contains('toast--out')).toBe(false)

    jest.advanceTimersByTime(1)
    expect(el.classList.contains('toast--out')).toBe(true)
  })

  it('respects custom duration', () => {
    toast('Custom', '', 1000)
    const el = document.querySelector('.toast')!

    jest.advanceTimersByTime(999)
    expect(el.classList.contains('toast--out')).toBe(false)

    jest.advanceTimersByTime(1)
    expect(el.classList.contains('toast--out')).toBe(true)
  })

  it('evicts oldest lowest-priority toast when exceeding MAX_TOASTS (10)', () => {
    // Fill container with 10 info toasts
    for (let i = 0; i < 10; i++) {
      toast(`Toast ${i}`, 'info')
    }
    expect(document.querySelector('.toast-container')!.children).toHaveLength(10)

    // Add one more — should evict the oldest info toast
    toast('Toast 10', 'info')
    expect(document.querySelector('.toast-container')!.children).toHaveLength(10)
    expect(document.querySelector('.toast-container')!.children[0].textContent).toContain('Toast 1')
  })

  it('preferentially evicts lower-priority toasts (success before error)', () => {
    // Add one error then fill with success toasts
    toast('Error toast', 'error')
    for (let i = 0; i < 9; i++) {
      toast(`Success ${i}`, 'success')
    }
    expect(document.querySelector('.toast-container')!.children).toHaveLength(10)

    // Add another error — should evict a success toast, not the error
    toast('Error toast 2', 'error')
    const toasts = document.querySelectorAll('.toast')
    const errorCount = Array.from(toasts).filter(t => t.classList.contains('toast--error')).length
    expect(errorCount).toBe(2)
    const successToasts = Array.from(toasts).filter(t => t.classList.contains('toast--success'))
    expect(successToasts).toHaveLength(8) // one success was evicted
  })
})

describe('toastWithAction', () => {
  beforeEach(() => {
    document.body.innerHTML = ''
    jest.useFakeTimers()
  })

  afterEach(() => {
    jest.useRealTimers()
  })

  it('renders toast with action buttons', () => {
    const onClick = jest.fn()
    const actions: ToastAction[] = [{ label: 'Retry', onClick }]

    toastWithAction('Failed', 'error', 5000, actions)

    const btn = document.querySelector('.toast__action-btn') as HTMLButtonElement
    expect(btn).not.toBeNull()
    expect(btn.textContent).toBe('Retry')
  })

  it('clicking action button removes toast and invokes handler', () => {
    const onClick = jest.fn()
    const actions: ToastAction[] = [{ label: 'Undo', onClick }]

    toastWithAction('Deleted', 'warning', 5000, actions)

    const btn = document.querySelector('.toast__action-btn') as HTMLButtonElement
    btn.click()

    expect(onClick).toHaveBeenCalledTimes(1)
    expect(document.querySelector('.toast')).toBeNull()
  })

  it('renders multiple action buttons', () => {
    const onRetry = jest.fn()
    const onDismiss = jest.fn()
    const actions: ToastAction[] = [
      { label: 'Retry', onClick: onRetry },
      { label: 'Dismiss', onClick: onDismiss },
    ]

    toastWithAction('Error', 'error', 5000, actions)

    const buttons = document.querySelectorAll('.toast__action-btn')
    expect(buttons).toHaveLength(2)
    expect(buttons[0].textContent).toBe('Retry')
    expect(buttons[1].textContent).toBe('Dismiss')
  })
})
