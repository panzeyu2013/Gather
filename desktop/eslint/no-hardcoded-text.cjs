// Static guard for i18n (design_improvements.md 4.4.3): flag JSX text nodes
// and string-literal aria-label/aria-description/placeholder/title attributes
// that contain natural language (CJK or an English sentence). The renderer
// has migrated to i18next; new copy must go through t() so it is
// translated and type-checked. Expression values (t('...')) are allowed.
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

/** @type {import('eslint').Rule.RuleModule} */
module.exports = {
  meta: {
    type: 'suggestion',
    docs: {
      description: 'Disallow non-i18n text in JSX children and string-literal aria/placeholder/title attributes',
      recommended: false,
    },
    messages: {
      hardcodedText: 'Hardcoded JSX text: use t() from the i18n framework (desktop/src/renderer/locales) instead of a literal.',
      hardcodedAttribute: 'Hardcoded "{{attr}}" attribute value: use t() from the i18n framework (desktop/src/renderer/locales) instead of a string literal.',
    },
  },
  create(context) {
    const FLAGGED_ATTRIBUTES = new Set(['aria-label', 'aria-description', 'placeholder', 'title'])

    return {
      JSXText(node) {
        const trimmed = node.value.trim()
        if (trimmed === '') return
        if (!isHardcodedCopy(trimmed)) return
        context.report({ node, messageId: 'hardcodedText' })
      },
      // Expression children like {'中文'} or {`${x} 张`} bypass JSXText;
      // flag the static parts (attribute values stay under JSXAttribute).
      JSXExpressionContainer(node) {
        if (node.parent.type !== 'JSXElement') return
        const expr = node.expression
        let text = null
        if (expr.type === 'Literal' && typeof expr.value === 'string') {
          text = expr.value
        } else if (expr.type === 'TemplateLiteral') {
          // Expressions inside the template are i18n-safe (t('...'), vars);
          // only the literal quasi parts carry copy.
          text = expr.quasis.map((quasi) => quasi.value.cooked).join('')
        }
        if (text === null) return
        const trimmed = text.trim()
        if (trimmed === '') return
        if (!isHardcodedCopy(trimmed)) return
        context.report({ node, messageId: 'hardcodedText' })
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
    }
  },
}
