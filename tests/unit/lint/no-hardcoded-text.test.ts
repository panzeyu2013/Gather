import { describe, expect, it } from 'vitest'
import { RuleTester } from 'eslint'
import noHardcodedText from '../../../desktop/eslint/no-hardcoded-text.cjs'

// Static i18n guard (docs/DESIGN_IMPROVEMENTS.md 4.4.3): JSX text nodes and
// string-literal aria-label/aria-description/placeholder/title attributes
// must go through t(). RuleTester uses ESLint's flat-config API; espree
// parses JSX via parserOptions.ecmaFeatures.jsx.
const ruleTester = new RuleTester({
  languageOptions: {
    ecmaVersion: 2022,
    sourceType: 'module',
    parserOptions: { ecmaFeatures: { jsx: true } },
  },
})

describe('gather/no-hardcoded-text', () => {
  it('flags CJK and English-sentence JSX text, allows expressions, symbols, numbers, single words', () => {
    ruleTester.run('no-hardcoded-text', noHardcodedText, {
      valid: [
        { code: '<div>{t(\'app.hello\')}</div>' },
        { code: '<div>{t(\'app.count\')} {count}</div>' },
        { code: '<button>×</button>' },
        { code: '<span>•</span>' },
        { code: '<div>…</div>' },
        { code: '<span>&gt;</span>' },
        { code: '<div>3</div>' },
        { code: '<div>Gather</div>' },
        { code: '<div>    </div>' },
        { code: '<div>Capture</div>' },
        { code: '<input placeholder="" />' },
        { code: '<div>{"×"}</div>' },
        { code: '<div>{`${count} photos`}</div>' },
        { code: '<div className={`${styles.a} ${styles.b}`}>x</div>' },
        { code: '<div>{`${styles.a}-${styles.b}`}</div>' },
      ],
      invalid: [
        { code: '<div>你好</div>', errors: [{ messageId: 'hardcodedText' }] },
        { code: '<div>Hello world</div>', errors: [{ messageId: 'hardcodedText' }] },
        { code: '<div>You have {count} photos</div>', errors: [{ messageId: 'hardcodedText' }] },
        { code: '<p>预检通过，可以导入。</p>', errors: [{ messageId: 'hardcodedText' }] },
        { code: '<div>共 {count} 张</div>', errors: 2 },
        { code: '<button>Save changes</button>', errors: [{ messageId: 'hardcodedText' }] },
        { code: '<div>{"中文"}</div>', errors: [{ messageId: 'hardcodedText' }] },
        { code: '<div>{`${x} 张`}</div>', errors: [{ messageId: 'hardcodedText' }] },
        { code: '<div>{`You have ${count} photos`}</div>', errors: [{ messageId: 'hardcodedText' }] },
      ],
    })
  })

  it('flags string-literal aria/placeholder/title values, allows t() expressions', () => {
    ruleTester.run('no-hardcoded-text', noHardcodedText, {
      valid: [
        { code: '<button aria-label={t(\'app.close\')} />' },
        { code: '<div aria-label={undefined} />' },
        { code: '<input aria-label="x" />' },
        { code: '<img alt="photo" />' },
      ],
      invalid: [
        { code: '<button aria-label="Close dialog">x</button>', errors: [{ messageId: 'hardcodedAttribute' }] },
        { code: '<div aria-label="删除照片" />', errors: [{ messageId: 'hardcodedAttribute' }] },
        { code: '<div aria-description="Long description text" />', errors: [{ messageId: 'hardcodedAttribute' }] },
        { code: '<input placeholder="Search photos" />', errors: [{ messageId: 'hardcodedAttribute' }] },
        { code: '<button title="Submit form">x</button>', errors: [{ messageId: 'hardcodedAttribute' }] },
      ],
    })
  })
})
