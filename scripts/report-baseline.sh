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
#     #expect/#require」口径，同时给出 core/app 分项与 docs/baselines/test-catalog-baseline.json 的 ratchet 值
#     （遮罩/计数实现单一来源：scripts/lib/swift-counts.py）
#   - 本地化：完整解析 en.lproj / zh-Hans.lproj Localizable.strings 的 key 数
#     （含转义引号、行注释、块注释；不依赖按行 grep）
#   - schema：SchemaCurrent.swift 的 expected* 常量（55 表/451 列/86 索引/81 外键/
#     user_version=1）；tables/indexes/FKs 与 DDL 字面量实测交叉核对（columns 取 expected 常量）
#   - 门禁脚本：scripts/check-*.sh 总数减 check-appintents.sh（自检，非门禁），
#     并列出清单，便于 docs/DEVELOPMENT 的门禁清单与 docs/README 的门禁数同步
#   - 性能 ratchet：docs/baselines/perf-baseline.json 的构造点基线 + Sources 当前实测
#     （口径同 scripts/check-perf-ratchet.sh：非纯注释行计数，Tests 不计）
#   - ratchet baseline：docs/baselines/surface-baseline.json（protocol-surface + modules sections）、
#     docs/baselines/cleanup-baseline.json 的字段值
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
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

# 共享计数单一来源：遮罩/计数口径只此一份（scripts/lib/swift-counts.py，
# check-test-catalog.sh / check-docs-facts.sh 同源；脚本已 cd 到仓库根）。
_SPEC = importlib.util.spec_from_file_location(
    'swift_counts', 'scripts/lib/swift-counts.py')
_COUNTS = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_COUNTS)
mask_comments = _COUNTS.mask_comments
count_decls = _COUNTS.count_decls

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
# mask_comments / count_decls 来自 scripts/lib/swift-counts.py（单一来源，
# check-test-catalog.sh / check-docs-facts.sh 同源）。


def count_test_decls(dirs):
    """core/app 分项计数；目录缺失 fail-closed（exit 1，stderr 指明缺哪个根）。"""
    for base in dirs:
        if not Path(base).is_dir():
            print('report-baseline: MISSING 测试目录 ' + base, file=sys.stderr)
            sys.exit(1)
    return count_decls(dirs)


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
TC_BASELINE = Path('docs/baselines/test-catalog-baseline.json')
if TC_BASELINE.is_file():
    try:
        tc_data = json.loads(TC_BASELINE.read_text(encoding='utf-8'))
    except (json.JSONDecodeError, OSError) as exc:
        print('report-baseline: FAIL 无法解析 %s（%s）' % (TC_BASELINE, exc), file=sys.stderr)
        sys.exit(1)
    tc_metrics = tc_data.get('metrics', {}) if isinstance(tc_data, dict) else {}
    bt = tc_metrics.get('test_decl')
    bs = tc_metrics.get('suite_decl')
    ba = tc_metrics.get('assert')
    if bt is not None and bs is not None and ba is not None:
        row('ratchet baseline（check-test-catalog.sh）',
            '@Test %s / @Suite %s / 断言 %s' % (bt, bs, ba))
else:
    row('ratchet baseline（check-test-catalog.sh）', 'MISSING docs/baselines/test-catalog-baseline.json')


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


# ---------------------------------------------------------------- 6) 门禁脚本
section('门禁脚本（scripts/check-*.sh，docs 口径）')
gate_files = sorted(Path('scripts').glob('check-*.sh'))
gate_names = [p.name for p in gate_files if p.name != 'check-appintents.sh']
row('门禁脚本数', len(gate_names))
note('排除：check-appintents.sh（需要已组装的 .app，是自检不是门禁）')
note('清单：' + ', '.join(gate_names))


# ---------------------------------------------------------------- 6b) 性能 ratchet
section('性能 ratchet（docs/baselines/perf-baseline.json + 当前实测；口径同 check-perf-ratchet.sh）')
PERF_SOURCES = [
    Path('desktop/native/gather-core/Sources'),
    Path('desktop/native/gather-app/Sources'),
]
PERF_METRICS = [
    ('raw_date_formatter', r'(^|[^A-Za-z0-9_])DateFormatter\(\)'),
    ('raw_iso_formatter', r'(^|[^A-Za-z0-9_])ISO8601DateFormatter\(\)'),
    ('raw_json_encoder', r'(^|[^A-Za-z0-9_])JSONEncoder\(\)'),
    ('raw_json_decoder', r'(^|[^A-Za-z0-9_])JSONDecoder\(\)'),
    ('raw_json_encode_chain', r'(^|[^A-Za-z0-9_])JSONEncoder\(\)\s*\.\s*encode'),
    ('raw_json_decode_chain', r'(^|[^A-Za-z0-9_])JSONDecoder\(\)\s*\.\s*decode'),
    ('raw_regex_compile', r'(^|[^A-Za-z0-9_])NSRegularExpression\('),
    ('raw_byte_formatter', r'(^|[^A-Za-z0-9_])ByteCountFormatter\(\)'),
    ('blocking_sleep', r'(^|[^A-Za-z0-9_])Thread\.sleep\('),
]
perf_files = sorted(p for root in PERF_SOURCES for p in root.rglob('*.swift'))
perf_current = {key: 0 for key, _ in PERF_METRICS}
for path in perf_files:
    if not path.is_file():
        continue
    for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
        stripped = line.lstrip()
        if stripped.startswith('//') or stripped.startswith('*'):
            continue
        for key, pattern in PERF_METRICS:
            if re.search(pattern, line):
                perf_current[key] += 1
row('扫描面', '%d 个 Sources Swift 文件（Tests 不计）' % len(perf_files))
PERF_BASELINE = Path('docs/baselines/perf-baseline.json')
if not PERF_BASELINE.is_file():
    row('baseline', 'MISSING docs/baselines/perf-baseline.json（check-perf-ratchet.sh 会 FAIL）')
else:
    try:
        perf_data = json.loads(PERF_BASELINE.read_text(encoding='utf-8'))
    except (json.JSONDecodeError, OSError) as exc:
        row('baseline', 'UNREADABLE docs/baselines/perf-baseline.json（%s）' % exc)
        perf_data = {}
    base_metrics = perf_data.get('metrics', {}) if isinstance(perf_data, dict) else {}
    row('baseline 元信息', '%s' % perf_data.get('generated_by', '?'))
    for key, cur in perf_current.items():
        base = base_metrics.get(key)
        if base is None:
            status = 'baseline 缺 key（门禁 FAIL）'
        elif cur > base:
            status = 'FAIL (+%d)' % (cur - base)
        elif cur < base:
            status = 'improved (-%d；可收紧 baseline)' % (base - cur)
        else:
            status = 'ok'
        row(key, 'current %d / baseline %s  %s'
            % (cur, base if base is not None else '?', status))


# ---------------------------------------------------------------- 7) ratchet baselines
def flatten(obj, prefix=''):
    out = []
    if isinstance(obj, dict):
        for key in sorted(obj):
            out.extend(flatten(obj[key], prefix + key + '.' if prefix else key + '.'))
    else:
        out.append((prefix[:-1], obj))
    return out


section('ratchet baseline 字段')
for label, path, section_key in (
    ('协议面（surface-baseline.json › gates.protocol-surface）',
     'docs/baselines/surface-baseline.json', 'protocol-surface'),
    ('模块级协议面（surface-baseline.json › gates.protocol-surface-modules）',
     'docs/baselines/surface-baseline.json', 'protocol-surface-modules'),
    ('清理（cleanup-baseline.json）', 'docs/baselines/cleanup-baseline.json', None),
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
    if section_key is not None:
        gates = data.get('gates', {}) if isinstance(data, dict) else {}
        data = gates.get(section_key)
        if data is None:
            print('report-baseline: FAIL %s 缺少 section gates.%s' % (path, section_key),
                  file=sys.stderr)
            sys.exit(1)
    note('-- ' + label)
    for key, value in sorted(flatten(data)):
        note(key + ': ' + str(value))


# ---------------------------------------------------------------- 8) 其余 ratchet 基线摘要
section('其余 ratchet 基线（摘要）')
try:
    structure = json.loads(Path('docs/baselines/structure-baseline.json').read_text(encoding='utf-8'))
    gates = structure.get('gates', {})
    lock = gates.get('lock-order', {})
    imp = gates.get('import-graph', {})
    con = gates.get('concurrency-whitelist', {})
    layer = gates.get('layer-symbols', {})
    pub = gates.get('public-surface-app', {})
    mod = gates.get('module-size', {})
    row('lock-order', 'violations %s / blocks %s / files %s / allowed fileLock sites %s'
        % (lock.get('baseline', {}).get('xmp_in_db_transaction'),
           lock.get('baseline', {}).get('transaction_blocks'),
           lock.get('baseline', {}).get('swift_files'),
           lock.get('baseline', {}).get('allowed_file_lock_run_sites')))
    row('import-graph', 'targets %s / files %s / internal imports %s'
        % (imp.get('scan', {}).get('targets'), imp.get('scan', {}).get('swift_files'),
           imp.get('scan', {}).get('internal_imports')))
    row('concurrency-whitelist', 'unchecked_sendable %s / nonisolated_unsafe %s / entries %s'
        % (con.get('scan', {}).get('totals', {}).get('unchecked_sendable'),
           con.get('scan', {}).get('totals', {}).get('nonisolated_unsafe'),
           len(con.get('entries', []))))
    row('layer-symbols', 'files %s / violations %s / hints %s / allowlist %s'
        % (layer.get('scan', {}).get('files'), layer.get('scan', {}).get('violations'),
           layer.get('scan', {}).get('hints'), len(layer.get('allowlist', []))))
    row('public-surface-app', 'protocols %s / requirement lines %s'
        % (pub.get('api', {}).get('public_protocols'), pub.get('api', {}).get('requirement_lines')))
    for pkg, meta in sorted(mod.get('packages', {}).items()):
        row('module-size ' + pkg, 'sources %s 行 / tests %s 行'
            % (meta.get('sources_loc'), meta.get('tests_loc')))
except (json.JSONDecodeError, OSError, AttributeError) as exc:
    row('structure-baseline', 'UNREADABLE（%s）' % exc)

try:
    port_row = json.loads(Path('docs/baselines/port-row-surface-baseline.json').read_text(encoding='utf-8'))
    row('port-row-surface', 'ports %s / methods %s / without fake %s / without effective fake %s / rows %s / app row refs %s / dbrow refs %s'
        % (port_row.get('metrics', {}).get('ports'),
           port_row.get('metrics', {}).get('port_methods'),
           port_row.get('metrics', {}).get('ports_without_fake'),
           port_row.get('metrics', {}).get('ports_without_effective_fake'),
           port_row.get('metrics', {}).get('persistence_public_row_types'),
           port_row.get('metrics', {}).get('persistence_row_refs_in_application'),
           port_row.get('metrics', {}).get('dbrow_refs_outside_persistence')))
except (json.JSONDecodeError, OSError) as exc:
    row('port-row-surface-baseline', 'UNREADABLE（%s）' % exc)

try:
    design = json.loads(Path('docs/baselines/design-system-baseline.json').read_text(encoding='utf-8'))
    for key, value in sorted(design.items()):
        note('design-system.' + key + ': ' + str(value))
except (json.JSONDecodeError, OSError) as exc:
    note('design-system-baseline: UNREADABLE（%s）' % exc)

print('')
print('----')
print('report-baseline: 只读事实报告完成（非门禁；数字不一致只提示，不影响 CI）')
sys.exit(1 if FAIL else 0)
PY_REPORT
