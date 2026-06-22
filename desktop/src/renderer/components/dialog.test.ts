import { dialog, typedConfirmDialog } from './dialog'

describe('dialog', () => {
  beforeEach(() => {
    document.body.innerHTML = ''
  })

  it('renders dialog overlay with confirm and cancel buttons', async () => {
    const promise = dialog('Are you sure?')

    const overlay = document.querySelector('.dialog-overlay')!
    expect(overlay).not.toBeNull()
    expect(overlay.querySelector('#dialogMessage')!.textContent).toBe('Are you sure?')
    expect(overlay.querySelector('#dialogTitle')!.textContent).toBe('Confirm')

    const okBtn = overlay.querySelector('#dialogOk') as HTMLButtonElement
    const cancelBtn = overlay.querySelector('#dialogCancel') as HTMLButtonElement
    expect(okBtn).not.toBeNull()
    expect(cancelBtn).not.toBeNull()

    // Cleanup
    cancelBtn.click()
    await expect(promise).resolves.toBe(false)
  })

  it('resolves true when OK button is clicked', async () => {
    const promise = dialog('Proceed?')
    const okBtn = document.querySelector('#dialogOk') as HTMLButtonElement
    okBtn.click()
    await expect(promise).resolves.toBe(true)
  })

  it('resolves false when Cancel button is clicked', async () => {
    const promise = dialog('Proceed?')
    const cancelBtn = document.querySelector('#dialogCancel') as HTMLButtonElement
    cancelBtn.click()
    await expect(promise).resolves.toBe(false)
  })

  it('resolves false when overlay background is clicked', async () => {
    const promise = dialog('Proceed?')
    const overlay = document.querySelector('.dialog-overlay') as HTMLDivElement
    overlay.click()
    await expect(promise).resolves.toBe(false)
  })

  it('resolves false on Escape key', async () => {
    const promise = dialog('Proceed?')
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await expect(promise).resolves.toBe(false)
  })

  it('uses custom confirm label', async () => {
    const promise = dialog('Delete?', 'Delete')
    const okBtn = document.querySelector('#dialogOk') as HTMLButtonElement
    expect(okBtn.textContent).toBe('Delete')
    okBtn.click()
    await expect(promise).resolves.toBe(true)
  })

  it('removes overlay from DOM after resolution', async () => {
    const promise = dialog('Test')
    const okBtn = document.querySelector('#dialogOk') as HTMLButtonElement
    okBtn.click()
    await promise
    expect(document.querySelector('.dialog-overlay')).toBeNull()
  })

  it('focuses OK button on open', () => {
    dialog('Test')
    expect(document.activeElement).toBe(document.querySelector('#dialogOk'))
  })

  it('restores previous focus on close', async () => {
    const input = document.createElement('input')
    input.id = 'prevFocus'
    document.body.appendChild(input)
    input.focus()
    expect(document.activeElement).toBe(input)

    const promise = dialog('Test')
    expect(document.activeElement).toBe(document.querySelector('#dialogOk'))

    const cancelBtn = document.querySelector('#dialogCancel') as HTMLButtonElement
    cancelBtn.click()
    await promise
    expect(document.activeElement).toBe(input)
  })

  it('traps Tab focus within dialog buttons', () => {
    dialog('Test')
    const okBtn = document.querySelector('#dialogOk') as HTMLButtonElement
    const cancelBtn = document.querySelector('#dialogCancel') as HTMLButtonElement

    // Focus is on OK initially
    expect(document.activeElement).toBe(okBtn)

    // Tab should move to Cancel
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab' }))
    expect(document.activeElement).toBe(cancelBtn)

    // Tab again should wrap to OK
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab' }))
    expect(document.activeElement).toBe(okBtn)

    // Shift+Tab should wrap to Cancel
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true }))
    expect(document.activeElement).toBe(cancelBtn)
  })

  it('resolves only once', async () => {
    const onResolve = jest.fn()
    dialog('Test').then(onResolve)

    // Click OK
    const okBtn = document.querySelector('#dialogOk') as HTMLButtonElement
    okBtn.click()
    okBtn.click()
    okBtn.click()
    await new Promise(r => setTimeout(r, 10))
    expect(onResolve).toHaveBeenCalledTimes(1)
  })

  it('requires typed confirmation text before resolving true', async () => {
    const promise = typedConfirmDialog('Delete all?', 'DELETE ALL', 'Delete All')
    const input = document.querySelector('#dialogTypedInput') as HTMLInputElement
    const okBtn = document.querySelector('#dialogOk') as HTMLButtonElement

    expect(document.activeElement).toBe(input)
    expect(okBtn.disabled).toBe(true)

    input.value = 'DELETE'
    input.dispatchEvent(new Event('input'))
    expect(okBtn.disabled).toBe(true)

    input.value = 'DELETE ALL'
    input.dispatchEvent(new Event('input'))
    expect(okBtn.disabled).toBe(false)

    okBtn.click()
    await expect(promise).resolves.toBe(true)
  })
})
