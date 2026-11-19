#!/usr/bin/env python3
r"""Swift 源码注释遮罩与 Testing 声明计数（单一来源）。

本文件是以下三处口径的唯一实现（改动只此一份）：
  - scripts/check-test-catalog.sh：ratchet 的 @Test/@Suite/#expect/#require 计数
  - scripts/report-baseline.sh：测试声明 core/app 分项与合计
  - scripts/check-docs-facts.sh：Package.swift / API Swift 源码遮罩

口径（与迁移前的内联实现逐字节一致）：
  mask_comments(text)：遮罩 // 行注释与可嵌套 /* */ 块注释（换行保留、输出与输入等长），
      字符串字面量（含三引号多行字符串、转义引号）原样保留，字符串里的 // 不会被当成注释。
  count_decls(roots)：对 roots 下全部 *.swift（每个根内按路径排序）先遮罩再计数：
      test_decl  = ^[ \t]*@Test([ \t]|\()
      suite_decl = ^[ \t]*(?:@[A-Za-z_]+[ \t]+)*@Suite([ \t(]|$)
      assert_n   = #(?:expect|require)\(
      调用方可传 loader(path) 复用已读文本（返回 None 时回退读盘）。

用法：
  python3 scripts/lib/swift-counts.py --self-test   # mktemp 夹具自测（注释/字符串/嵌套注释）
  python3 scripts/lib/swift-counts.py --help
"""
import re
import shutil
import sys
import tempfile
from pathlib import Path

# 与迁移前 check-test-catalog.sh / report-baseline.sh 内联正则逐字节一致。
TEST_RE = re.compile(r'^[ \t]*@Test([ \t]|\()', re.M)
SUITE_RE = re.compile(r'^[ \t]*(?:@[A-Za-z_]+[ \t]+)*@Suite([ \t(]|$)', re.M)
ASSERT_RE = re.compile(r'#(?:expect|require)\(')


def mask_comments(text):
    """遮罩注释、保留字符串字面量（输出与输入等长，行号不漂移）。"""
    out = list(text)
    n = len(text)
    i = 0
    while i < n:
        c = text[i]
        if c == '"':
            if text.startswith('"""', i):
                j = text.find('"""', i + 3)
                i = n if j < 0 else j + 3
                continue
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == '"' or text[j] == '\n':
                    j += 1
                    break
                j += 1
            i = j
            continue
        if text.startswith('//', i):
            j = text.find('\n', i)
            if j < 0:
                j = n
            for k in range(i, j):
                out[k] = ' '
            i = j
            continue
        if text.startswith('/*', i):
            depth = 0
            j = i
            while j < n:
                if text.startswith('/*', j):
                    depth += 1
                    j += 2
                    continue
                if text.startswith('*/', j):
                    depth -= 1
                    j += 2
                    if depth == 0:
                        break
                    continue
                j += 1
            for k in range(i, min(j, n)):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
            continue
        i += 1
    return ''.join(out)


def count_decls(roots, loader=None):
    """统计 roots 下 *.swift 的 (@Test, @Suite, #expect+#require) 声明数。

    loader 可选：loader(path) 返回调用方已读文本，返回 None 时回退读盘；
    单个文件读盘失败（OSError）跳过，与 check-test-catalog.sh 旧行为一致。
    """
    test_decl = 0
    suite_decl = 0
    assert_n = 0
    for base in roots:
        for path in sorted(Path(base).rglob('*.swift')):
            text = loader(path) if loader is not None else None
            if text is None:
                try:
                    text = path.read_text(encoding='utf-8', errors='replace')
                except OSError:
                    continue
            masked = mask_comments(text)
            test_decl += len(TEST_RE.findall(masked))
            suite_decl += len(SUITE_RE.findall(masked))
            assert_n += len(ASSERT_RE.findall(masked))
    return test_decl, suite_decl, assert_n


def _blank_span(src):
    """把一段注释按 mask_comments 约定替换为等长空白（换行保留），用于自测期望值。"""
    return ''.join('\n' if c == '\n' else ' ' for c in src)


TOP_FIXTURE = '''// 文件头注释：注释里的 @Test / @Suite 都不算声明
import Testing

// @Test func commentedOut() {}
/* @Suite struct Blocked {} */
@Suite struct TopSuite {
    @Test func plain() {
        #expect(1 == 1)
        #require(true)
    }

    // @Test(.disabled) func commentedTrait() {}
    @Test(.enabled(if: true))
    func trait() {
        let url = "https://example.com" // 字符串里的 // 不是注释
        #expect(url.contains("example"))
    }
}
'''

DEEP_FIXTURE = '''// 嵌套夹具：多行字符串与嵌套块注释
import Testing
/* 外层 /* 内层 */ 外层 */
@Test func deep() {
    let s = """
    // 多行字符串里的 // 不是注释
    """
    #expect(s.isEmpty == false)
}
'''


def self_test():
    """mktemp 夹具自测：注释/字符串/嵌套注释/多行字符串 + count_decls 口径。"""
    checked = 0
    failures = []

    def check(name, actual, expected):
        nonlocal checked
        checked += 1
        if actual != expected:
            failures.append('%s: 期望 %r，实际 %r' % (name, expected, actual))

    fixtures = [
        ('行注释', '// @Test func fake() {}\n@Test func real() {}\n'),
        ('行尾注释', 'let s = "a" // trailing\n'),
        ('字符串保留', 'let url = "https://example.com"\n'),
        ('字符串内 //', 'let s = "a // b"\n#expect(true)\n'),
        ('嵌套块注释', '/* a /* b */ c */\n@Test func real() {}\n'),
        ('未闭合块注释', '/* a\n#expect(true)\n'),
        ('多行字符串', 'let s = """\n// not comment\n#expect(1)\n"""\n'),
        ('转义引号', r'let s = "a \" b" // c' + '\n'),
        ('CRLF', '// c\r\n#expect(true)\r\n'),
    ]
    for label, src in fixtures:
        masked = mask_comments(src)
        check('mask/长度不变 ' + label, len(masked), len(src))
        check('mask/换行保留 ' + label, masked.count('\n'), src.count('\n'))

    check('mask/行注释', mask_comments('// @Test func fake() {}\n@Test func real() {}\n'),
          _blank_span('// @Test func fake() {}') + '\n@Test func real() {}\n')
    check('mask/行尾注释', mask_comments('let s = "a" // trailing\n'),
          'let s = "a" ' + _blank_span('// trailing') + '\n')
    check('mask/字符串保留', mask_comments('let url = "https://example.com"\n'),
          'let url = "https://example.com"\n')
    check('mask/字符串内 // 不算注释', mask_comments('let s = "a // b"\n#expect(true)\n'),
          'let s = "a // b"\n#expect(true)\n')
    check('mask/多行字符串保留', mask_comments('let s = """\n// not comment\n#expect(1)\n"""\n'),
          'let s = """\n// not comment\n#expect(1)\n"""\n')
    check('mask/嵌套块注释', mask_comments('/* a /* b */ c */\n@Test func real() {}\n'),
          _blank_span('/* a /* b */ c */') + '\n@Test func real() {}\n')
    check('mask/未闭合块注释', mask_comments('/* a\n#expect(true)\n'),
          _blank_span('/* a') + '\n' + _blank_span('#expect(true)') + '\n')
    escaped = r'let s = "a \" b" // c' + '\n'
    check('mask/转义引号', mask_comments(escaped),
          r'let s = "a \" b" ' + _blank_span('// c') + '\n')

    tmp = tempfile.mkdtemp(prefix='swift-counts-selftest.')
    try:
        root = Path(tmp) / 'root'
        (root / 'Nested').mkdir(parents=True)
        (root / 'Top.swift').write_text(TOP_FIXTURE, encoding='utf-8')
        (root / 'Nested' / 'Deep.swift').write_text(DEEP_FIXTURE, encoding='utf-8')
        check('count/合计', count_decls([root]), (3, 1, 4))
        check('count/子目录', count_decls([root / 'Nested']), (1, 0, 1))
        check('count/loader 覆盖', count_decls([root], loader=lambda _path: '/* @Test */\n'), (0, 0, 0))
        check('count/loader 回退', count_decls(
            [root], loader=lambda path: None if path.name == 'Deep.swift' else ''), (1, 0, 1))
        check('count/缺目录', count_decls([root / 'Missing']), (0, 0, 0))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        for item in failures:
            print('swift-counts: SELFTEST FAILED — ' + item, file=sys.stderr)
        return 1
    print('swift-counts: SELFTEST OK（%d 项：注释/字符串保留/嵌套注释/计数口径）' % checked)
    return 0


def main(argv):
    if argv and argv[0] in ('-h', '--help'):
        print(__doc__.strip())
        return 0
    if argv == ['--self-test']:
        return self_test()
    print('swift-counts: 未知参数 %r（用法：--self-test）' % (argv,), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
