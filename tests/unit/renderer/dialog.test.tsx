import React, { useRef, useState } from 'react'
import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi, afterEach } from 'vitest'
import Dialog from '../../../desktop/src/renderer/components/Dialog/Dialog'
import ConfirmDialog from '../../../desktop/src/renderer/components/Dialog/ConfirmDialog'

afterEach(() => {
  document.querySelector('main')?.removeAttribute('inert')
})

describe('Dialog focus management', () => {
  it('moves focus into the dialog on open', () => {
    render(
      <Dialog open onClose={() => {}} title="测试对话框">
        <button>选项 A</button>
        <button>选项 B</button>
      </Dialog>,
    )
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Close' }))
  })

  it('focuses the initialFocus target when provided', () => {
    function WithInitialFocus() {
      const targetRef = useRef<HTMLButtonElement>(null)
      return (
        <Dialog open onClose={() => {}} title="测试对话框" initialFocus={targetRef}>
          <button>选项 A</button>
          <button ref={targetRef}>目标按钮</button>
        </Dialog>
      )
    }
    render(<WithInitialFocus />)
    expect(document.activeElement).toBe(screen.getByRole('button', { name: '目标按钮' }))
  })

  it('traps Tab and Shift+Tab at the dialog boundaries', () => {
    render(
      <Dialog open onClose={() => {}} title="测试对话框">
        <button>选项 A</button>
        <button>选项 B</button>
      </Dialog>,
    )
    const first = screen.getByRole('button', { name: 'Close' })
    const last = screen.getByRole('button', { name: '选项 B' })

    last.focus()
    fireEvent.keyDown(document, { key: 'Tab' })
    expect(document.activeElement).toBe(first)

    fireEvent.keyDown(document, { key: 'Tab', shiftKey: true })
    expect(document.activeElement).toBe(last)
  })

  it('does not let focus escape when the dialog has no focusable elements', () => {
    const preventDefault = vi.spyOn(KeyboardEvent.prototype, 'preventDefault')
    render(
      <Dialog open onClose={() => {}} title="测试对话框">
        <p>仅文字内容</p>
      </Dialog>,
    )
    fireEvent.keyDown(document, { key: 'Tab' })
    expect(preventDefault).toHaveBeenCalled()
  })

  it('restores focus to the trigger element on close', () => {
    function Harness() {
      const [open, setOpen] = useState(false)
      return (
        <div>
          <button onClick={() => setOpen(true)}>打开</button>
          {open && (
            <Dialog open onClose={() => setOpen(false)} title="测试对话框">
              <button>选项 A</button>
            </Dialog>
          )}
        </div>
      )
    }
    render(<Harness />)
    const trigger = screen.getByRole('button', { name: '打开' })
    trigger.focus()
    fireEvent.click(trigger)

    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Close' }))
    fireEvent.click(screen.getByRole('button', { name: 'Close' }))
    expect(document.activeElement).toBe(trigger)
  })

  it('closes on Escape', () => {
    const onClose = vi.fn()
    render(
      <Dialog open onClose={onClose} title="测试对话框">
        <button>选项 A</button>
      </Dialog>,
    )
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('wires aria-labelledby to the visible title and omits aria-describedby when undefined', () => {
    render(
      <Dialog open onClose={() => {}} title="测试对话框">
        <button>选项 A</button>
      </Dialog>,
    )
    const dialog = screen.getByRole('dialog')
    const title = screen.getByText('测试对话框')
    expect(dialog.getAttribute('aria-labelledby')).toBe(title.id)
    expect(title.tagName).toBe('H2')
    expect(dialog.hasAttribute('aria-describedby')).toBe(false)
  })

  it('applies aria-describedby when a descriptionId is provided', () => {
    render(
      <Dialog open onClose={() => {}} title="测试对话框" descriptionId="desc-1">
        <p id="desc-1">简单描述</p>
        <button>选项 A</button>
      </Dialog>,
    )
    expect(screen.getByRole('dialog').getAttribute('aria-describedby')).toBe('desc-1')
  })

  it('marks the background main region inert while open and un-inerts it on close', () => {
    const { rerender } = render(
      <main>
        <Dialog open onClose={() => {}} title="测试对话框">
          <button>选项 A</button>
        </Dialog>
      </main>,
    )
    const main = document.querySelector('main')
    expect(main).not.toBeNull()
    expect(main!.hasAttribute('inert')).toBe(true)

    rerender(
      <main>
        <Dialog open={false} onClose={() => {}} title="测试对话框">
          <button>选项 A</button>
        </Dialog>
      </main>,
    )
    expect(main!.hasAttribute('inert')).toBe(false)
  })
})

describe('ConfirmDialog', () => {
  it('focuses the cancel button for destructive confirmations', () => {
    render(
      <ConfirmDialog
        open
        onClose={() => {}}
        onConfirm={() => {}}
        title="删除确认"
        message="确定要删除吗？"
        confirmLabel="删除"
        destructive
      />,
    )
    // Labels resolve through i18next (en fallback in the test env).
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Cancel' }))
  })

  it('focuses the cancel button by default for non-destructive confirmations', () => {
    render(
      <ConfirmDialog
        open
        onClose={() => {}}
        onConfirm={() => {}}
        title="确认操作"
        message="确定要执行吗？"
      />,
    )
    // Least-destructive-first (APG): cancel is the default focus target.
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Cancel' }))
  })
})
