#!/usr/bin/env bash
# 文档事实门禁（2026-11-17，gate #16）：文档里的基线数字必须与源码事实一致。
#
# 背景：round-1 起 README / docs/README / docs/DEVELOPMENT 会写死基线数字
# （targets、域 API、schema、本地化 key、门禁脚本数）。数字只靠人记会漂，
# 本门禁把「源码计算」与「文档断言」对齐：任一侧变化而未同步，直接 FAIL 并打印
# 期望值 vs 文档现状（含 file:line），不再靠评审肉眼核对。
#
# 计算口径（与 scripts/report-baseline.sh、既有各门禁一致）：
#   - SwiftPM targets：两个 Package.swift 的 .target/.executableTarget/.testTarget 声明数
#     （注释不计；functional = 6 个 core 库 target + GatherUI/GatherHost/GatherApp，
#     排除 CSQLite/GatherTestSupport/GatherPreviewData/bench/工具/测试 target）
#   - 域 API：GatherProtocol/API/*API.swift 的顶层 protocol 数 + 花括号内 func 需求数
#   - 本地化：完整解析 en.lproj / zh-Hans.lproj Localizable.strings 的 key 数
#   - schema：SchemaCurrent.swift 的 expectedTableCount/expectedColumnCount/
#     expectedExplicitIndexCount/expectedForeignKeyCount 常量
#   - 门禁脚本数：scripts/check-*.sh 总数减 scripts/check-appintents.sh
#     （check-appintents 需要已组装的 .app，是自检不是门禁）
#
# 文档断言（全部按上一步「计算值」构造期望串，故源码数字变化时门禁不会自证绿灯）：
#   - README.md：<N> typed domain APIs (<M> methods)；<word> functional SwiftPM targets (<T> total
#   - docs/README.md：<N> 个域 API / <M> 个类型化方法；<F> 个功能 target（含测试/工具共 <T> 个）；
#     <A> 表 / <B> 列 / <C> 索引 / <D> 外键；en <E> 键 / zh-Hans <Z> 占位键；
#     <G> 个 check-*.sh 门禁（check-*.sh 两侧的反引号按文档原文构造）
#   - docs/DEVELOPMENT.md：每个门禁脚本都必须以 ./scripts/<name>.sh 出现在「门禁」清单里
#     （check-appintents.sh 除外，它是自检）
#
# 只读、确定性（无时间戳，输出排序固定）、只依赖 git/bash/python3；带扫描量守卫，
# 解析器失效时 fail closed，不会静默 0 命中。
#
# 用法：./scripts/check-docs-facts.sh
# exit 0 = 事实与文档一致；exit 1 = 任一项不一致（消息含期望值、文档现状与行号）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for tool in git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "check-docs-facts: FAIL 缺少依赖 $tool" >&2
    exit 1
  fi
done

python3 - <<'PY_DOCS'
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

FAIL = False
REPO = Path.cwd()
BT = chr(96)


def fail(msg):
    global FAIL
    FAIL = True
    print('    FAIL ' + msg)


def ok(msg):
    print('    ok    ' + msg)


def section(title):
    print(title)


# mask_comments 单一来源：scripts/lib/swift-counts.py（遮罩口径与 report-baseline.sh 同源）。
_SPEC = importlib.util.spec_from_file_location(
    'swift_counts', 'scripts/lib/swift-counts.py')
_COUNTS = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_COUNTS)
mask_comments = _COUNTS.mask_comments


def line_of(text, needle):
    idx = text.find(needle)
    if idx < 0:
        return None
    return text.count('\n', 0, idx) + 1


# ---------------------------------------------------------------- 0) git 仓库
section('[facts] 源码计算')
try:
    top = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()
except (subprocess.CalledProcessError, OSError) as exc:
    print('    FAIL 不在 git 仓库内（%s）' % exc)
    sys.exit(1)
ok('git 仓库：%s' % top)

# ---------------------------------------------------------------- 1) SwiftPM targets
PACKAGES = [
    ('gather-core', 'desktop/native/gather-core/Package.swift'),
    ('gather-app', 'desktop/native/gather-app/Package.swift'),
]
KINDS = ['executableTarget', 'testTarget', 'binaryTarget', 'plugin', 'target']
parsed = {}
for pkg, rel in PACKAGES:
    path = REPO / rel
    if not path.is_file():
        fail('缺少 %s' % rel)
        continue
    text = mask_comments(path.read_text(encoding='utf-8'))
    found = {}
    for kind in KINDS:
        names = []
        for m in re.finditer(r'\.' + kind + r'\s*\(', text):
            nm = re.search(r'name:\s*"([^"]+)"', text[m.end():m.end() + 2000])
            names.append(nm.group(1) if nm else '?')
        found[kind] = names
    parsed[pkg] = found
if len(parsed) != 2:
    print('check-docs-facts: FAIL 无法解析两个 Package.swift')
    sys.exit(1)
core_total = sum(len(v) for v in parsed['gather-core'].values())
app_total = sum(len(v) for v in parsed['gather-app'].values())
total_targets = core_total + app_total
core_libs = [n for n in parsed['gather-core']['target']
             if n not in ('CSQLite', 'GatherTestSupport')]
app_code = [n for n in parsed['gather-app']['target'] if n in ('GatherUI', 'GatherHost')]
app_exec = [n for n in parsed['gather-app']['executableTarget'] if n == 'GatherApp']
functional = core_libs + app_code + app_exec
if core_total < 8 or app_total < 3 or total_targets < 12:
    fail('target 计数异常：gather-core %d / gather-app %d / 合计 %d（疑似解析器失效）'
         % (core_total, app_total, total_targets))
if len(functional) < 7:
    fail('functional target 只识别到 %d 个（<7），疑似解析器失效' % len(functional))
ok('SwiftPM targets：gather-core %d / gather-app %d / 合计 %d / functional %d'
   % (core_total, app_total, total_targets, len(functional)))

# ---------------------------------------------------------------- 2) 域 API
API = REPO / 'desktop/native/gather-core/Sources/GatherProtocol/API'
api_files = sorted(API.rglob('*.swift')) if API.is_dir() else []
domain_files = sorted(API.glob('*API.swift')) if API.is_dir() else []
if len(api_files) < 40:
    fail('GatherProtocol/API 只扫到 %d 个 *.swift（<40），疑似路径异常' % len(api_files))
domain_protocols = []
requirement_n = 0
for path in domain_files:
    text = mask_comments(path.read_text(encoding='utf-8'))
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
        body = text[start + 1:i - 1]
        domain_protocols.append(m.group(1))
        requirement_n += len(re.findall(
            r'(?m)^\s*(?:static\s+|mutating\s+|nonisolated\s+)*func\s+[A-Za-z_]', body))
if len(domain_protocols) < 10 or requirement_n < 100:
    fail('域 API 解析异常：protocol %d / method %d（疑似解析器失效）'
         % (len(domain_protocols), requirement_n))
ok('域 API：%d 协议 / %d 方法（*API.swift 顶层 protocol 的 func 需求）'
   % (len(domain_protocols), requirement_n))

# ---------------------------------------------------------------- 3) 本地化 key 数
def count_strings_keys(rel):
    path = REPO / rel
    if not path.is_file():
        fail('缺少 %s' % rel)
        return None
    text = path.read_text(encoding='utf-8')
    n = len(text)
    state = {'i': 0}

    def skip_ws_comments():
        while state['i'] < n:
            c = text[state['i']]
            if c in ' \t\r\n':
                state['i'] += 1
            elif text.startswith('//', state['i']):
                j = text.find('\n', state['i'])
                state['i'] = n if j < 0 else j + 1
            elif text.startswith('/*', state['i']):
                j = text.find('*/', state['i'] + 2)
                state['i'] = n if j < 0 else j + 2
            else:
                return

    def read_quoted():
        assert text[state['i']] == '"'
        state['i'] += 1
        while state['i'] < n:
            c = text[state['i']]
            if c == '\\':
                state['i'] += 2
            elif c == '"':
                state['i'] += 1
                return
            else:
                state['i'] += 1
        raise ValueError('字符串未闭合')

    count = 0
    while True:
        skip_ws_comments()
        if state['i'] >= n:
            return count
        try:
            read_quoted()
            skip_ws_comments()
            if state['i'] >= n or text[state['i']] != '=':
                raise ValueError('缺 =')
            state['i'] += 1
            skip_ws_comments()
            read_quoted()
            skip_ws_comments()
            if state['i'] >= n or text[state['i']] != ';':
                raise ValueError('缺 ;')
            state['i'] += 1
            count += 1
        except ValueError as exc:
            fail('%s 条目结构非法（%s）' % (rel, exc))
            return None


RES = 'desktop/native/gather-app/Sources/GatherUI/Resources/'
en_keys = count_strings_keys(RES + 'en.lproj/Localizable.strings')
zh_keys = count_strings_keys(RES + 'zh-Hans.lproj/Localizable.strings')
if en_keys is None or zh_keys is None:
    print('check-docs-facts: FAIL 本地化表解析失败')
    sys.exit(1)
if en_keys < 2000 or zh_keys < 5:
    fail('本地化 key 计数异常：en %d / zh-Hans %d（疑似解析器失效）' % (en_keys, zh_keys))
ok('本地化：en %d / zh-Hans %d keys' % (en_keys, zh_keys))

# ---------------------------------------------------------------- 4) schema 计数
schema = REPO / 'desktop/native/gather-core/Sources/GatherPersistence/Database/SchemaCurrent.swift'
if not schema.is_file():
    fail('缺少 %s' % schema.relative_to(REPO))
    print('check-docs-facts: FAIL 无法计算 schema 事实')
    sys.exit(1)
main_text = schema.read_text(encoding='utf-8')
schema_facts = {}
for name in ('TableCount', 'ColumnCount', 'ExplicitIndexCount', 'ForeignKeyCount'):
    m = re.search(r'expected' + name + r':\s*Int\s*=\s*(\d+)', main_text)
    if not m:
        fail('SchemaCurrent.swift 缺少 expected%s 常量' % name)
        schema_facts[name] = None
    else:
        schema_facts[name] = int(m.group(1))
if any(v is None or v < 1 for v in schema_facts.values()):
    print('check-docs-facts: FAIL schema 常量解析失败')
    sys.exit(1)
ok('schema：%d 表 / %d 列 / %d 索引 / %d 外键'
   % (schema_facts['TableCount'], schema_facts['ColumnCount'],
      schema_facts['ExplicitIndexCount'], schema_facts['ForeignKeyCount']))

# ---------------------------------------------------------------- 5) 门禁脚本数
scripts_dir = REPO / 'scripts'
gate_names = sorted(p.name for p in scripts_dir.glob('check-*.sh'))
gate_scripts = [name for name in gate_names if name != 'check-appintents.sh']
gate_count = len(gate_scripts)
if gate_count < 12:
    fail('scripts/check-*.sh 只扫到 %d 个门禁脚本（<12），疑似路径异常' % gate_count)
ok('门禁脚本：%d（scripts/check-*.sh %d 个 - check-appintents.sh 1 个）'
   % (gate_count, len(gate_names)))

# ---------------------------------------------------------------- 6) 文档断言
def check_claim(rel, expected, hint):
    path = REPO / rel
    if not path.is_file():
        fail('缺少文档 %s' % rel)
        return
    text = path.read_text(encoding='utf-8')
    line = line_of(text, expected)
    if line is not None:
        ok('%s L%d  %s' % (rel, line, expected))
        return
    fail('%s 缺少事实断言（期望 "%s"）' % (rel, expected))
    found = [(idx + 1, ln.strip()) for idx, ln in enumerate(text.split('\n'))
             if re.search(hint, ln)]
    if found:
        for no, ln in found[:3]:
            print('          文档现状 L%d: %s' % (no, ln[:160]))
    else:
        print('          文档现状：未找到相近行（hint=%s）' % hint)


NUMWORDS = {1: 'one', 2: 'two', 3: 'three', 4: 'four', 5: 'five', 6: 'six', 7: 'seven',
            8: 'eight', 9: 'nine', 10: 'ten', 11: 'eleven', 12: 'twelve'}
section('[docs] README.md / docs/README.md')
check_claim('README.md',
            '%d typed domain APIs (%d methods)' % (len(domain_protocols), requirement_n),
            r'\d+ typed domain APIs')
check_claim('README.md',
            '%s functional SwiftPM targets (%d total'
            % (NUMWORDS.get(len(functional), str(len(functional))), total_targets),
            r'(?:nine|functional SwiftPM targets)')
check_claim('docs/README.md',
            '%d 个域 API / %d 个类型化方法' % (len(domain_protocols), requirement_n),
            r'\d+ 个域 API / \d+ 个类型化方法')
check_claim('docs/README.md',
            '%d 个功能 target（含测试/工具共 %d 个）' % (len(functional), total_targets),
            r'\d+ 个功能 target')
check_claim('docs/README.md',
            '%d 表 / %d 列 / %d 索引 / %d 外键'
            % (schema_facts['TableCount'], schema_facts['ColumnCount'],
               schema_facts['ExplicitIndexCount'], schema_facts['ForeignKeyCount']),
            r'\d+ 表 / \d+ 列')
check_claim('docs/README.md',
            'en {:,} 键 / zh-Hans {} 占位键'.format(en_keys, zh_keys),
            r'en [\d,]+ 键')
check_claim('docs/README.md',
            '%d 个 %scheck-*.sh%s 门禁' % (gate_count, BT, BT),
            r'\d+ 个 ' + BT + r'check-\*\.sh' + BT + r' 门禁')

# ---------------------------------------------------------------- 7) 门禁清单
section('[gate-list] docs/DEVELOPMENT.md')
dev = REPO / 'docs/DEVELOPMENT.md'
if not dev.is_file():
    fail('缺少 docs/DEVELOPMENT.md')
else:
    dev_text = dev.read_text(encoding='utf-8')
    # 评审 R4-F1 / round-2 R2D-04 / round-3 R3T-01~04：门禁清单只认「## 门禁」小节内
    # fenced code block 里以 ./scripts/ 开头的命令行；正文/注释/裸行不算数。
    gate_section = ''
    start = dev_text.find('\n## 门禁')
    if start >= 0:
        rest = dev_text[start + 1:]
        nxt = rest.find('\n## ', 1)
        gate_section = rest if nxt < 0 else rest[:nxt]
    if not gate_section:
        fail('docs/DEVELOPMENT.md 缺少「## 门禁」小节')
    listed = set()
    listed_cmds = []
    in_fence = False
    for line in gate_section.splitlines():
        stripped = line.strip()
        if stripped.startswith(BT * 3):
            in_fence = not in_fence
            continue
        if not in_fence:
            continue
        if stripped.startswith('#'):
            continue
        if stripped.startswith('- '):
            stripped = stripped[2:].strip()
        if stripped.startswith('./scripts/'):
            cmd = stripped.split('  #')[0].split(' #')[0].strip()
            listed_cmds.append(cmd)
            listed.add(cmd.split()[0])
    missing = []
    for name in gate_scripts:
        needle = './scripts/' + name
        if needle not in listed:
            missing.append(needle)
    if missing:
        for needle in missing:
            fail('docs/DEVELOPMENT.md 门禁清单缺少：%s' % needle)
    else:
        ok('docs/DEVELOPMENT.md 列出了全部 %d 个门禁脚本（check-appintents.sh 除外）'
           % gate_count)
    # 评审 R4-F2 / round-3 R3T-01/02：CI wiring 必须是「真的会被执行」的精确 run 行：
    # 完整命令行逐字符匹配；禁止附加参数/短路/包装/echo/注释；禁止 if:false 与
    # continue-on-error；门禁 job 必须属于会跑的工作流 job（warnings 在测试 job）。
    ci = REPO / '.github/workflows/ci.yml'
    if not ci.is_file():
        fail('缺少 .github/workflows/ci.yml')
    else:
        ci_all = ci.read_text(encoding='utf-8').splitlines()
        jobs = {}
        current_job = None
        in_jobs = False
        for idx, line in enumerate(ci_all):
            if re.match(r'^jobs:\s*(#.*)?$', line):
                in_jobs = True
                continue
            if not in_jobs:
                continue
            m = re.match(r'^  ([A-Za-z0-9_-]+):\s*(#.*)?$', line)
            if m:
                current_job = m.group(1)
                jobs[current_job] = []
                continue
            if current_job is not None:
                jobs[current_job].append((idx, line))

        def norm_expr(value):
            v = value.strip().lower()
            v = re.sub(r'^\$\{\{\s*', '', v)
            v = re.sub(r'\s*\}\}$', '', v)
            return v.strip()

        def guard_value(ln, key):
            m = re.match(r'^\s*' + key + r':\s*(.*?)\s*$', ln)
            if not m:
                return None
            return norm_expr(m.group(1))

        def job_has_guard(lines):
            # 只把 job 级（4 空格缩进）if/continue-on-error 视为禁用；step 级由 step_has_guard 判。
            for _, ln in lines:
                if ln.strip().startswith('#'):
                    continue
                if re.match(r'^    if:', ln) and guard_value(ln, 'if') == 'false':
                    return True
                if re.match(r'^    continue-on-error:', ln) and guard_value(ln, 'continue-on-error') == 'true':
                    return True
            return False

        def step_has_guard(lines, run_idx):
            start = 0
            for pos, (_, ln) in enumerate(lines):
                if re.match(r'^\s*-\s', ln) and pos <= run_idx:
                    start = pos
            for pos in range(start, len(lines)):
                if pos > start and re.match(r'^\s*-\s', lines[pos][1]):
                    break
                ln = lines[pos][1]
                if ln.strip().startswith('#'):
                    continue
                if guard_value(ln, 'if') == 'false' or guard_value(ln, 'continue-on-error') == 'true':
                    return True
            return False

        def run_commands(lines, pos):
            m = re.match(r'^\s*(?:-\s*)?run:\s*(.*?)\s*$', lines[pos][1])
            if not m:
                return None
            value = m.group(1)
            if value in ('|', '|-', '|+', '>', '>-', '>+'):
                indent = len(lines[pos][1]) - len(lines[pos][1].lstrip())
                out = []
                for pos2 in range(pos + 1, len(lines)):
                    ln = lines[pos2][1]
                    if not ln.strip():
                        continue
                    if len(ln) - len(ln.lstrip()) <= indent:
                        break
                    out.append(ln.strip())
                return out
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ('\'', '"'):
                return [value[1:-1]]
            return [value]

        allowed_jobs = {
            'check-warnings.sh': ('gather-core', 'gather-app'),
        }

        def expected_jobs(script):
            for key, val in allowed_jobs.items():
                if script == key:
                    return val
            return ('boundary', 'gates')

        unwired = []
        masked = []
        loose = []
        for cmd in listed_cmds:
            script = cmd.split()[0].rsplit('/', 1)[-1]
            if script not in gate_scripts:
                continue  # 门禁小节里的非门禁辅助脚本（如 report-baseline）不参与接线断言
            exact = []
            for job, lines in jobs.items():
                if job not in expected_jobs(script):
                    continue
                for pos in range(len(lines)):
                    cmds = run_commands(lines, pos)
                    if cmds is None:
                        continue
                    if cmds != [cmd]:
                        continue
                    if job_has_guard(lines) or step_has_guard(lines, pos):
                        masked.append(cmd)
                    else:
                        exact.append(job)
            if exact:
                continue
            containing = False
            for job, lines in jobs.items():
                for _, ln in lines:
                    if cmd in ln and 'run:' in ln:
                        containing = True
            if containing:
                loose.append(cmd)
            else:
                unwired.append(cmd)
        if unwired:
            for cmd in unwired:
                fail('CI 未按文档命令精确接入门禁：%s' % cmd)
        if loose:
            for cmd in loose:
                fail('CI 门禁命令出现但非精确 run 行（包装/附加参数/短路风险）：%s' % cmd)
        if masked:
            for cmd in masked:
                fail('CI 门禁命令被 if:false / continue-on-error 静默禁用：%s' % cmd)
        if not unwired and not loose and not masked:
            ok('CI 已按文档命令精确接入全部 %d 个门禁脚本（无禁用/短路）' % gate_count)

print('----')
if FAIL:
    print('check-docs-facts: FAILED（按上面期望值/行号同步文档后重跑；文档事实以源码计算为准）')
    sys.exit(1)
print('check-docs-facts: OK')
sys.exit(0)
PY_DOCS
