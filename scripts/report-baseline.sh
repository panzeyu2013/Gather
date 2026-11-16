#!/usr/bin/env bash
# 仓库基线事实报告（只读；**不是门禁**，不接入 CI，也不会因为数字变化而失败）。
#
# 用途：docs/README.md、docs/ROADMAP.md、docs/DEVELOPMENT.md 等文档重新校准数字时，
# 直接运行本脚本取事实，不要手猜或从旧评审文档抄。输出确定性（无时间戳、排序固定），
# 只有 source 行随 git HEAD/工作树状态变化，便于文档标注采样来源。
#
# 口径（与既有门禁一致，避免文档和门禁各算一套）：
#   - SwiftPM targets：Package.swift 的 .target/.executableTarget/.testTarget 声明数
#     （注释行不计；products = .library/.executable 声明数）
#   - API 契约：GatherProtocol/API/*API.swift 的顶层 protocol 数 + 花括号内 func 需求数
#     （即文档的「16 个域协议 / 195 个方法」口径；extension 默认实现不计入方法数）
#   - 测试声明：与 scripts/check-test-catalog.sh 相同的「先剥注释、再数 @Test/@Suite/
#     #expect/#require」口径，同时给出 core/app 分项与 ratchet baseline 常量
#   - 本地化：完整解析 en.lproj / zh-Hans.lproj Localizable.strings 的 key 数
#     （含转义引号、行注释、块注释；不依赖按行 grep）
#   - schema：SchemaCurrent.swift 的 expected* 常量（55 表/451 列/86 索引/81 外键/
#     user_version=1）与 DDL 字面量实测计数交叉核对
#   - ratchet baseline：docs/protocol-surface-baseline.json、
#     docs/protocol-surface-modules-baseline.json、docs/cleanup-baseline.json 的字段值
#
# 只读：不写任何文件；缺输入/缺少 git 或 python3 时 exit 1，数字口径不一致只提示不失败。
# 用法：./scripts/report-baseline.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for tool in git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "report-baseline: FAIL 缺少依赖 $tool" >&2
    exit 1
  fi
done

python3 - <<'PY_REPORT'
import json
import re
import subprocess
import sys
from pathlib import Path

FAIL = False


def section(title):
    print('')
    print('== ' + title)


def row(label, value):
    print('  ' + label + ': ' + str(value))


def note(text):
    print('  ' + text)


# ---------------------------------------------------------------- 来源
try:
    head = subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD'], text=True).strip()
    dirty = '+dirty' if subprocess.check_output(['git', 'status', '--porcelain'], text=True).strip() else ''
except (subprocess.CalledProcessError, OSError) as exc:
    print('report-baseline: FAIL 无法读取 git 状态（%s）' % exc, file=sys.stderr)
    sys.exit(1)

print('gather repo baseline（只读事实报告；非门禁）')
print('source: git ' + head + dirty)


# ---------------------------------------------------------------- helpers
def mask_comments(text):
    """遮罩 // 与 嵌套 /* */ 注释（保留字符串）；用于 Swift 源码计数。"""
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


def count_test_decls(dirs):
    chunks = []
    for base in dirs:
        root = Path(base)
        if not root.is_dir():
            print('report-baseline: MISSING 测试目录 ' + base, file=sys.stderr)
            sys.exit(1)
        for path in sorted(root.rglob('*.swift')):
            chunks.append(mask_comments(path.read_text(encoding='utf-8', errors='replace')))
    blob = '\n'.join(chunks)
    return (
        len(re.findall(r'^[ \t]*@Test([ \t]|\()', blob, re.M)),
        len(re.findall(r'^[ \t]*(?:@[A-Za-z_]+[ \t]+)*@Suite([ \t(]|$)', blob, re.M)),
        len(re.findall(r'#(?:expect|require)\(', blob)),
    )


# ---------------------------------------------------------------- 1) SwiftPM targets
section('SwiftPM targets（Package.swift）')
PACKAGES = [
    ('gather-core', 'desktop/native/gather-core/Package.swift'),
    ('gather-app', 'desktop/native/gather-app/Package.swift'),
]
KINDS = ['executableTarget', 'testTarget', 'binaryTarget', 'plugin', 'target']
parsed = {}
total_targets = 0
for pkg, path in PACKAGES:
    p = Path(path)
    if not p.is_file():
        print('report-baseline: MISSING ' + path, file=sys.stderr)
        sys.exit(1)
    text = mask_comments(p.read_text(encoding='utf-8'))
    found = {}
    for kind in KINDS:
        names = []
        for m in re.finditer(r'\.' + kind + r'\s*\(', text):
            rest = text[m.end():m.end() + 2000]
            nm = re.search(r'name:\s*"([^"]+)"', rest)
            names.append(nm.group(1) if nm else '?')
        found[kind] = names
    products = {
        'library': len(re.findall(r'\.library\s*\(', text)),
        'executable': len(re.findall(r'\.executable\s*\(', text)),
    }
    n_targets = sum(len(v) for v in found.values())
    total_targets += n_targets
    parsed[pkg] = {'targets': found, 'products': products, 'total': n_targets}
    kinds_txt = ' / '.join('%s %d' % (k, len(found[k])) for k in KINDS if found[k])
    prod_txt = ' / '.join('%s %d' % (k, v) for k, v in products.items() if v)
    row(pkg, 'targets %d（%s）；products %d（%s）'
        % (n_targets, kinds_txt, sum(products.values()), prod_txt))
row('合计', 'targets %d' % total_targets)

core_libs = [n for n in parsed['gather-core']['targets']['target']
             if n not in ('CSQLite', 'GatherTestSupport')]
app_code = [n for n in parsed['gather-app']['targets']['target'] if n in ('GatherUI', 'GatherHost')]
app_exec = [n for n in parsed['gather-app']['targets']['executableTarget'] if n == 'GatherApp']
functional = core_libs + app_code + app_exec
row('functional targets（docs 口径 %d）' % len(functional), ', '.join(functional))
note('口径：6 个 core 库 target + GatherUI/GatherHost/GatherApp；排除 CSQLite/GatherTestSupport/')
note('      GatherPreviewData（预览夹具）/bench/工具/测试 target。')
section('target 明细')
for pkg, info in parsed.items():
    for kind in KINDS:
        names = info['targets'][kind]
        if names:
            note('%s %s（%d）: %s' % (pkg, kind, len(names), ', '.join(names)))


# ---------------------------------------------------------------- 2) API 契约
section('GatherProtocol API 契约（Sources/GatherProtocol/API）')
api_dir = Path('desktop/native/gather-core/Sources/GatherProtocol/API')
if not api_dir.is_dir():
    print('report-baseline: MISSING ' + str(api_dir), file=sys.stderr)
    sys.exit(1)
api_files = sorted(api_dir.rglob('*.swift'))
domain_files = sorted(api_dir.glob('*API.swift'))
domain_protocols = []
requirement_n = 0
func_total = 0


def protocol_bodies(text):
    for m in re.finditer(r'(?m)^\s*(?:public\s+)?protocol\s+([A-Za-z_][A-Za-z0-9_]*)', text):
        start = text.find('{', m.end())
        if start < 0:
            continue
        depth = 1
        i = start + 1
        while i < len(text) and depth:
            if text[i] == '{':
                depth += 1
            elif text[i] == '}':
                depth -= 1
            i += 1
        yield m.group(1), text[start + 1:i - 1]


for path in domain_files:
    text = mask_comments(path.read_text(encoding='utf-8'))
    for name, body in protocol_bodies(text):
        domain_protocols.append(name)
        requirement_n += len(re.findall(r'(?m)^\s*(?:static\s+|mutating\s+|nonisolated\s+)*func\s+[A-Za-z_]', body))
    func_total += len(re.findall(r'(?m)^\s*func\s+[A-Za-z_]', text))

support_protocols = []
for path in api_files:
    text = mask_comments(path.read_text(encoding='utf-8'))
    for name, _body in protocol_bodies(text):
        if name not in domain_protocols:
            support_protocols.append(name)

row('API 文件（含 Core/Inputs/Outputs/Errors）', len(api_files))
row('域协议（*API.swift 顶层 protocol）', len(domain_protocols))
row('协议方法（protocol requirement funcs）', requirement_n)
row('*API.swift 内 func 总数（含 extension 默认实现）', func_total)
row('支撑协议（不计入域协议）', ', '.join(sorted(support_protocols)) or '0')


# ---------------------------------------------------------------- 3) 测试声明
section('测试声明（check-test-catalog 口径：剥注释后计数）')
CORE_TEST_DIRS = [
    'desktop/native/gather-core/Tests/GatherCoreTests',
    'desktop/native/gather-core/Tests/GatherTestSupport',
]
APP_TEST_DIRS = ['desktop/native/gather-app/Tests/GatherAppTests']
core_t, core_s, core_a = count_test_decls(CORE_TEST_DIRS)
app_t, app_s, app_a = count_test_decls(APP_TEST_DIRS)
row('core（GatherCoreTests + GatherTestSupport）', '@Test %d / @Suite %d / #expect+#require %d'
    % (core_t, core_s, core_a))
row('app（GatherAppTests）', '@Test %d / @Suite %d / #expect+#require %d' % (app_t, app_s, app_a))
row('合计', '@Test %d / @Suite %d / #expect+#require %d' % (core_t + app_t, core_s + app_s, core_a + app_a))
ratchet = Path('scripts/check-test-catalog.sh')
if ratchet.is_file():
    text = ratchet.read_text(encoding='utf-8')
    bt = re.search(r'^BASELINE_TEST_DECL=(\d+)', text, re.M)
    bs = re.search(r'^BASELINE_SUITE_DECL=(\d+)', text, re.M)
    ba = re.search(r'^BASELINE_ASSERT=(\d+)', text, re.M)
    if bt and bs and ba:
        row('ratchet baseline（check-test-catalog.sh）',
            '@Test %s / @Suite %s / 断言 %s' % (bt.group(1), bs.group(1), ba.group(1)))


# ---------------------------------------------------------------- 4) 本地化 key 数
section('本地化（Resources/*.lproj/Localizable.strings 的 key 数）')


def parse_strings(path):
    text = path.read_text(encoding='utf-8')
    n = len(text)
    entries = []
    state = {'i': 0, 'line': 1}

    def skip_ws_comments():
        while state['i'] < n:
            c = text[state['i']]
            if c == '\n':
                state['line'] += 1
                state['i'] += 1
            elif c in ' \t\r':
                state['i'] += 1
            elif text.startswith('//', state['i']):
                j = text.find('\n', state['i'])
                if j < 0:
                    state['i'] = n
                    return
                state['i'] = j + 1
                state['line'] += 1
            elif text.startswith('/*', state['i']):
                j = text.find('*/', state['i'] + 2)
                if j < 0:
                    state['i'] = n
                    return
                state['line'] += text.count('\n', state['i'], j + 2)
                state['i'] = j + 2
            else:
                return

    def read_quoted():
        state['i'] += 1
        buf = []
        while state['i'] < n:
            c = text[state['i']]
            if c == '\\':
                state['i'] += 2
                buf.append('')
            elif c == '"':
                state['i'] += 1
                return ''.join(buf)
            else:
                if c == '\n':
                    state['line'] += 1
                buf.append(c)
                state['i'] += 1
        raise ValueError('unterminated string')

    while True:
        skip_ws_comments()
        if state['i'] >= n:
            break
        try:
            key = read_quoted()
            skip_ws_comments()
            if text[state['i']] != '=':
                raise ValueError('expected =')
            state['i'] += 1
            skip_ws_comments()
            read_quoted()
            skip_ws_comments()
            if text[state['i']] != ';':
                raise ValueError('expected ;')
            state['i'] += 1
            entries.append(key)
        except (ValueError, IndexError) as exc:
            print('report-baseline: FAIL 解析 %s 失败（%s）' % (path, exc), file=sys.stderr)
            sys.exit(1)
    return entries


for lang in ('en', 'zh-Hans'):
    path = Path('desktop/native/gather-app/Sources/GatherUI/Resources/%s.lproj/Localizable.strings' % lang)
    if not path.is_file():
        print('report-baseline: MISSING ' + str(path), file=sys.stderr)
        sys.exit(1)
    entries = parse_strings(path)
    row(lang, '%d keys' % len(entries))


# ---------------------------------------------------------------- 5) schema
section('SQLite schema（SchemaCurrent.swift，唯一 DDL）')
schema_main = Path('desktop/native/gather-core/Sources/GatherPersistence/Database/SchemaCurrent.swift')
schema_dir = schema_main.parent / 'Schema'
if not schema_main.is_file():
    print('report-baseline: MISSING ' + str(schema_main), file=sys.stderr)
    sys.exit(1)
main_text = schema_main.read_text(encoding='utf-8')
expected = {}
for key in ('TableCount', 'ColumnCount', 'ExplicitIndexCount', 'ForeignKeyCount'):
    m = re.search(r'expected' + key + r':\s*Int\s*=\s*(\d+)', main_text)
    expected[key] = int(m.group(1)) if m else None
m_ver = re.search(r'userVersion:\s*Int\s*=\s*(\d+)', main_text)
m_fp = re.search(r'expectedShapeFingerprint:\s*String\s*=\s*\n?\s*"([0-9a-f]+)"', main_text)


def schema_files_count(pattern):
    total = 0
    for path in [schema_main] + sorted(schema_dir.glob('SchemaCurrent+DDL*.swift')):
        for line in path.read_text(encoding='utf-8').splitlines():
            stripped = line.strip()
            if stripped.startswith('//') or stripped.startswith('--'):
                continue
            total += len(re.findall(pattern, stripped))
    return total


actual_tables = schema_files_count(r'CREATE TABLE(?: IF NOT EXISTS)?\s+[A-Za-z_]')
actual_indexes = schema_files_count(r'CREATE (?:UNIQUE )?INDEX(?: IF NOT EXISTS)?\s+[A-Za-z_]')
actual_fks = schema_files_count(r'\bREFERENCES\b')
row('user_version', m_ver.group(1) if m_ver else '?')
row('expected* 常量', 'tables %s / columns %s / explicit indexes %s / foreign keys %s'
    % tuple(str(expected[k]) for k in ('TableCount', 'ColumnCount', 'ExplicitIndexCount', 'ForeignKeyCount')))
row('DDL 实测', 'tables %d / indexes %d / foreign keys %d' % (actual_tables, actual_indexes, actual_fks))
mismatch = []
if expected['TableCount'] is not None and actual_tables != expected['TableCount']:
    mismatch.append('tables expected %s != actual %d' % (expected['TableCount'], actual_tables))
if expected['ExplicitIndexCount'] is not None and actual_indexes != expected['ExplicitIndexCount']:
    mismatch.append('indexes expected %s != actual %d' % (expected['ExplicitIndexCount'], actual_indexes))
if expected['ForeignKeyCount'] is not None and actual_fks != expected['ForeignKeyCount']:
    mismatch.append('foreign keys expected %s != actual %d' % (expected['ForeignKeyCount'], actual_fks))
if mismatch:
    row('cross-check', 'MISMATCH（expected* 与 DDL 字面量不一致，文档不要采信旧数）：' + '；'.join(mismatch))
else:
    row('cross-check', 'expected* 与 DDL 字面量一致')
row('shape fingerprint', m_fp.group(1) if m_fp else '?')


# ---------------------------------------------------------------- 6) ratchet baselines
def flatten(obj, prefix=''):
    out = []
    if isinstance(obj, dict):
        for key in sorted(obj):
            out.extend(flatten(obj[key], prefix + key + '.' if prefix else key + '.'))
    else:
        out.append((prefix[:-1], obj))
    return out


section('ratchet baseline 字段')
for label, path in (
    ('协议面（protocol-surface-baseline.json）', 'docs/protocol-surface-baseline.json'),
    ('模块级协议面（protocol-surface-modules-baseline.json）',
     'docs/protocol-surface-modules-baseline.json'),
    ('清理（cleanup-baseline.json）', 'docs/cleanup-baseline.json'),
):
    p = Path(path)
    if not p.is_file():
        print('report-baseline: MISSING ' + path, file=sys.stderr)
        sys.exit(1)
    try:
        data = json.loads(p.read_text(encoding='utf-8'))
    except (json.JSONDecodeError, OSError) as exc:
        print('report-baseline: FAIL 无法解析 %s（%s）' % (path, exc), file=sys.stderr)
        sys.exit(1)
    note('-- ' + label)
    for key, value in sorted(flatten(data)):
        note(key + ': ' + str(value))

print('')
print('----')
print('report-baseline: 只读事实报告完成（非门禁；数字不一致只提示，不影响 CI）')
sys.exit(1 if FAIL else 0)
PY_REPORT
