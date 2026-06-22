// src/renderer/components/dom.ts
// 类型安全的 DOM 工具

export function $<T extends HTMLElement>(sel: string, parent: ParentNode = document): T | null {
  return parent.querySelector<T>(sel)
}
export function $$<T extends HTMLElement>(sel: string, parent: ParentNode = document): NodeListOf<T> {
  return parent.querySelectorAll<T>(sel)
}
let _escDiv: HTMLDivElement
export function esc(s: string): string {
  if (!_escDiv) {
    _escDiv = document.createElement('div')
  }
  _escDiv.textContent = String(s)
  // NOTE: .textContent setter already escapes HTML entities in innerHTML.
  // The .replace() calls for quotes are technically no-ops but preserved here
  // for defense-in-depth in case the DOM serialization behavior changes.
  return _escDiv.innerHTML.replace(/"/g, '&quot;').replace(/'/g, '&#39;')
}

export function on(
  parent: HTMLElement,
  event: string,
  selector: string,
  handler: (el: HTMLElement, e: Event) => void,
): () => void {
  const listener = (e: Event) => {
    const target = (e.target as HTMLElement).closest<HTMLElement>(selector)
    if (target) handler.call(target, target, e)
  }
  parent.addEventListener(event, listener)
  return () => parent.removeEventListener(event, listener)
}

export function setText(id: string, v: string | number): void {
  const e = document.getElementById(id) ?? $(id)
  if (e) e.textContent = String(v)
}
