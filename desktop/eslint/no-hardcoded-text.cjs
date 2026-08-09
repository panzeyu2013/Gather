// Static guard for i18n (docs/DESIGN_IMPROVEMENTS.md 4.4.3): flag JSX text
// nodes, JSX expression literals (including ternary/logical branches) and
// string-literal aria-label/aria-description/placeholder/title attributes
// that contain natural language (CJK or an English sentence). Any string
// literal containing CJK anywhere in a renderer .tsx file is user-facing
// copy too (setState/toast/error payloads), so it is flagged regardless of
// JSX position. Expression values (t('...')) are allowed.
'use strict'

const CJK_RE = /[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/

function containsCjk(text) {
  return CJK_RE.test(text)
}

// An "English sentence" is ≥2 whitespace-separated ASCII words. Numbers and
// single words (brand tokens like "Gather") are allowed, as are
// whitespace/punctuation/symbol-only text ('×', '•', '…', '>').
function isEnglishSentence(text) {
  const words = text.match(/[a-zA-Z]+/g)
  return words !== null && words.length >= 2
}

function isHardcodedCopy(text) {
  return containsCjk(text) || isEnglishSentence(text)
}

// Collect the static copy parts of an expression: string/template literals,
// recursing through ternary and logical branches so `cond ? '收起' : t('k')`
// and `a && '中文'` are caught, not just top-level literals.
function collectExpressionStrings(node, out) {
  if (!node) return
  switch (node.type) {
    case 'Literal':
      if (typeof node.value === 'string') out.push(node.value)
      break
    case 'TemplateLiteral':
      out.push(node.quasis.map((quasi) => quasi.value.cooked).join(''))
      break
    case 'ConditionalExpression':
      collectExpressionStrings(node.consequent, out)
      collectExpressionStrings(node.alternate, out)
      break
    case 'LogicalExpression':
      collectExpressionStrings(node.left, out)
      collectExpressionStrings(node.right, out)
      break
    case 'ParenthesizedExpression':
      collectExpressionStrings(node.expression, out)
      break
    default:
      break
  }
}

/** @type {import('eslint').Rule.RuleModule} */
module.exports = {
  meta: {
    type: 'suggestion',
    docs: {
      description: 'Disallow non-i18n text in JSX children, string-literal aria/placeholder/title attributes, and CJK string literals anywhere in renderer .tsx files',
      recommended: false,
    },
    messages: {
      hardcodedText: 'Hardcoded JSX text: use t() from the i18n framework (desktop/src/renderer/locales) instead of a literal.',
      hardcodedAttribute: 'Hardcoded "{{attr}}" attribute value: use t() from the i18n framework (desktop/src/renderer/locales) instead of a string literal.',
      hardcodedLiteral: 'Hardcoded CJK string literal: use t() from the i18n framework (desktop/src/renderer/locales) instead of a raw literal.',
    },
  },
  create(context) {
    const FLAGGED_ATTRIBUTES = new Set(['aria-label', 'aria-description', 'placeholder', 'title'])
    const sourceCode = context.sourceCode

    return {
      JSXText(node) {
        const trimmed = node.value.trim()
        if (trimmed === '') return
        if (!isHardcodedCopy(trimmed)) return
        context.report({ node, messageId: 'hardcodedText' })
      },
      // Expression children like {'中文'}, {`${x} 张`} or ternary branches
      // bypass JSXText; flag the static parts. Attribute values (className=,
      // to=, src=…) are route/style expressions, not copy, so only direct
      // JSXElement children are scanned.
      JSXExpressionContainer(node) {
        if (node.parent.type !== 'JSXElement') return
        const strings = []
        collectExpressionStrings(node.expression, strings)
        for (const text of strings) {
          const trimmed = text.trim()
          if (trimmed === '') continue
          if (!isHardcodedCopy(trimmed)) continue
          context.report({ node, messageId: 'hardcodedText' })
          return
        }
      },
      JSXAttribute(node) {
        const attrName = node.name && node.name.type === 'JSXIdentifier' ? node.name.name : null
        if (attrName === null || !FLAGGED_ATTRIBUTES.has(attrName)) return
        const value = node.value
        // Expression values (aria-label={t('...')}) are fine; only string
        // literals are checked.
        if (value === null || value.type !== 'Literal') return
        if (typeof value.value !== 'string') return
        if (!isHardcodedCopy(value.value)) return
        context.report({ node, messageId: 'hardcodedAttribute', data: { attr: attrName } })
      },
      // CJK string literals outside JSX (setState/toast/error payloads in
      // .tsx files) are user-facing copy; JSX subtrees are already covered by
      // the visitors above, so they are skipped here to avoid double reports.
      'Program:exit'(node) {
        const walk = (child, inJsx) => {
          if (!child || typeof child.type !== 'string') return
          const nodeInJsx = inJsx || child.type === 'JSXElement'
          if (!inJsx) {
            let text = null
            if (child.type === 'Literal' && typeof child.value === 'string') {
              text = child.value
            } else if (child.type === 'TemplateLiteral') {
              text = child.quasis.map((quasi) => quasi.value.cooked).join('')
            }
            if (text !== null && containsCjk(text.trim())) {
              context.report({ node: child, messageId: 'hardcodedLiteral' })
            }
          }
          for (const key of Object.keys(child)) {
            if (key === 'parent') continue
            const value = child[key]
            if (Array.isArray(value)) value.forEach((item) => walk(item, nodeInJsx))
            else walk(value, nodeInJsx)
          }
        }
        walk(node, false)
      },
    }
  },
}
