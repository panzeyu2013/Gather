#!/usr/bin/env bash
# 仓库卫生门禁（2026-11-17）：补齐原 14 个门禁未覆盖的「仓库层」约束。
#
# 设计目标：只读、Linux 可跑（不依赖 macOS/Swift/构建产物），只依赖 git / bash / python3；
# 唯一例外是 [f] 需要 shellcheck（CI ubuntu-latest 预装）：缺失时只让 [f] FAIL 并打印安装提示。
# 检查面（每节独立 PASS/FAIL，失败打印可复核的 file:line）：
#   [a] 脚本自身卫生
#       - scripts 下 *.sh 与 desktop/native/build.sh 过 bash -n，且 stderr 必须为空
#         （守住 heredoc 未闭合这类「还能跑但已经坏了」的回归）；
#       - scripts 下 *.py 过 python3 -m py_compile（字节码落临时目录，不污染仓库）；
#       - 所有 tracked 的 shebang 文件必须有执行位（chmod +x）；
#       - *.sh 不得含 CR（CRLF / 孤 CR 都会让 shebang 失效）。
#   [b] .editorconfig 一致性（tracked 文本文件：swift/md/sh/py/json/yml/yaml/strings/txt + .editorconfig）
#       - end_of_line=lf；trim_trailing_whitespace（含纯空白行）；insert_final_newline；charset=utf-8。
#   [c] Markdown 相对链接
#       - tracked *.md 中 [x](path) / ![x](path) 必须解析到 tracked 文件（CI checkout 里也存在）；
#       - 跳过 http(s)/mailto/其它 scheme、#锚点、协议相对 //、尖括号形式；
#       - 跳过围栏代码块（三个反引号或三个波浪线）与行内代码（反引号包裹）——示例代码不是链接。
#   [d] 本地化表安全（Resources 的 en.lproj / zh-Hans.lproj Localizable.strings）
#       - 可完整解析（注释 + "key" = "value";），无残留非法片段；
#       - 无重复 key、无空 value；
#       - en 的 value 不含 CJK（en 界面不应回落中文）；
#       - key 与 value 的 printf 占位符多重集一致：%% 是字面 %，不参与占位符；
#         孤立的 %（后面不是合法转换符）视为普通文本，不算占位符。
#   [e] scripts/ 下不得提交缓存/构建产物（__pycache__、*.pyc/pyo、.build/、build/、*.o/*.a 等）。
#   [f] shellcheck 静态检查（tracked *.sh，severity warning）
#       - 全部 tracked *.sh 过 shellcheck -S warning -f gcc；任何 finding 即 FAIL（打印 file:line:col）；
#       - SHELLCHECK_OPTS 置空，避免本机环境变量改规则（如 -e SCxxxx）导致门禁结果不确定；
#       - 扫描量下限 15 个 *.sh；shellcheck 缺失时本节 FAIL 并打印安装提示。
#
# 防「静默 0 命中」守卫：每个检查面都有扫描量下限（文件数 / 链接数 / key 数 / 占位符数），
# 低于下限直接 FAIL，避免路径或解析器失效时门禁变绿。
#
# 用法：./scripts/check-repo-hygiene.sh
# exit 0 = 六节全过；exit 1 = 至少一节失败（消息含节名与文件行号）。
# 非目标：不做 macOS 构建、不改文件、不检查 docs 措辞（事实校准见 scripts/report-baseline.sh）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for tool in git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "check-repo-hygiene: FAIL 缺少依赖 $tool" >&2
    exit 1
  fi
done

FAIL=0
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "check-repo-hygiene: 仓库卫生门禁"

# ===== [a] 脚本语法 / shebang 执行位 / CRLF =====
echo "[a] 脚本语法 / shebang 执行位 / CRLF"
if python3 - "$SCRATCH" <<'PY_A'
import os
import subprocess
import sys

scratch = sys.argv[1]

tracked = subprocess.check_output(['git', 'ls-files', '-z']).split(b'\0')
tracked = sorted(p.decode('utf-8', 'surrogateescape') for p in tracked if p)
if not tracked:
    print('    FAIL git ls-files 返回 0 个 tracked 文件，疑似不在 git 检出内')
    sys.exit(1)

fail = False


def dump(text):
    for line in text.splitlines():
        print('        ' + line)


# 1) bash -n：stderr 必须为空（warning 也是错）。
sh_files = [p for p in tracked if p.endswith('.sh')]
sh_bad = []
if len(sh_files) < 15:
    print('    FAIL 只扫到 %d 个 .sh（<15），疑似 git 路径/检出异常' % len(sh_files))
    fail = True
for path in sh_files:
    proc = subprocess.run(['bash', '-n', path], capture_output=True, text=True)
    if proc.returncode != 0:
        print('    FAIL bash -n 失败：%s' % path)
        dump(proc.stderr.strip())
        sh_bad.append(path)
    elif proc.stderr.strip():
        print('    FAIL bash -n stderr 非空（如 heredoc 未闭合）：%s' % path)
        dump(proc.stderr.strip())
        sh_bad.append(path)
if sh_bad:
    fail = True
else:
    print('    ok    bash -n：%d 个 .sh，stderr 全空' % len(sh_files))

# 2) python3 -m py_compile（PYTHONPYCACHEPREFIX 指向临时目录，避免写仓库 __pycache__）。
py_files = [p for p in tracked if p.startswith('scripts/') and p.endswith('.py')]
py_bad = []
if len(py_files) < 2:
    print('    FAIL 只扫到 %d 个 scripts/**/*.py（<2），疑似 git 路径/检出异常' % len(py_files))
    fail = True
env = dict(os.environ)
env['PYTHONPYCACHEPREFIX'] = os.path.join(scratch, 'pycache')
for path in py_files:
    proc = subprocess.run(
        [sys.executable or 'python3', '-m', 'py_compile', path],
        capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        print('    FAIL py_compile 失败：%s' % path)
        dump(proc.stderr.strip())
        py_bad.append(path)
if py_bad:
    fail = True
else:
    print('    ok    py_compile：%d 个 scripts/**/*.py' % len(py_files))

# 3) shebang 文件必须有执行位（git 检出的 100755；stat 位判定不受 root 影响）。
shebang_files = []
for path in tracked:
    try:
        with open(path, 'rb') as fh:
            if fh.read(2) == b'#!':
                shebang_files.append(path)
    except OSError as exc:
        print('    FAIL 无法读取：%s（%s）' % (path, exc))
        fail = True
shebang_bad = []
if len(shebang_files) < 20:
    print('    FAIL 只扫到 %d 个 shebang 文件（<20），疑似扫描面失效' % len(shebang_files))
    fail = True
for path in shebang_files:
    mode = os.stat(path).st_mode
    if not (mode & 0o111):
        print('    FAIL shebang 文件缺执行位：%s（chmod +x）' % path)
        shebang_bad.append(path)
if shebang_bad:
    fail = True
else:
    print('    ok    shebang 执行位：%d 个文件全部可执行' % len(shebang_files))

# 4) *.sh 不得含 CR（CRLF 或孤 CR）。
crlf_bad = []
for path in sh_files:
    with open(path, 'rb') as fh:
        if b'\r' in fh.read():
            print('    FAIL .sh 含 CR（应仅 LF）：%s' % path)
            crlf_bad.append(path)
if crlf_bad:
    fail = True
else:
    print('    ok    .sh 无 CR：%d 个' % len(sh_files))

sys.exit(1 if fail else 0)
PY_A
then
  echo "    PASS"
else
  echo "    FAIL"
  FAIL=1
fi

# ===== [b] .editorconfig 一致性 =====
echo "[b] .editorconfig 一致性（LF / 无行尾空白 / 末行换行 / UTF-8）"
if python3 - <<'PY_B'
import subprocess
import sys

TEXT_EXT = (
    '.swift', '.md', '.sh', '.py', '.json', '.yml', '.yaml', '.strings', '.txt',
)
EDITORCONFIG = '.editorconfig'

tracked = subprocess.check_output(['git', 'ls-files', '-z']).split(b'\0')
tracked = sorted(p.decode('utf-8', 'surrogateescape') for p in tracked if p)
files = [p for p in tracked if p.endswith(TEXT_EXT) or p == EDITORCONFIG]

fail = False
if len(files) < 1000:
    print('    FAIL 只扫到 %d 个文本文件（<1000），疑似扫描面失效' % len(files))
    fail = True
if EDITORCONFIG not in files:
    print('    FAIL 缺少 %s' % EDITORCONFIG)
    fail = True

problems = []
for path in files:
    try:
        data = open(path, 'rb').read()
    except OSError as exc:
        problems.append((path, 'read error: %s' % exc))
        continue
    if b'\r' in data:
        problems.append((path, 'has CR (end_of_line=lf)'))
        continue
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as exc:
        problems.append((path, 'not UTF-8: %s' % exc))
        continue
    if not text:
        continue
    for no, line in enumerate(text.split('\n'), 1):
        if line != line.rstrip(' \t'):
            problems.append((path, 'L%d trailing whitespace (trim_trailing_whitespace)' % no))
            break
    if not text.endswith('\n'):
        problems.append((path, 'missing final newline (insert_final_newline)'))

if problems:
    fail = True
    shown = problems[:40]
    for path, why in shown:
        print('    FAIL %s：%s' % (path, why))
    if len(problems) > len(shown):
        print('    FAIL ... 另有 %d 个文件不合规（合计 %d）' % (len(problems) - len(shown), len(problems)))

if fail:
    sys.exit(1)
print('    ok    %d 个文本文件全部符合' % len(files))
PY_B
then
  echo "    PASS"
else
  echo "    FAIL"
  FAIL=1
fi

# ===== [c] Markdown 相对链接 =====
echo "[c] Markdown 相对链接"
if python3 - <<'PY_C'
import os
import re
import subprocess
import sys
from urllib.parse import unquote

BT = chr(96)
LINK = re.compile(r'(!?)\[([^\]]*)\]\(([^()\s]*(?:\([^()]*\))?[^()\s]*)\)')
SCHEME = re.compile(r'^[A-Za-z][A-Za-z0-9+.-]*:')

tracked = subprocess.check_output(['git', 'ls-files', '-z']).split(b'\0')
tracked = sorted(p.decode('utf-8', 'surrogateescape') for p in tracked if p)
tracked_set = set(tracked)
md_files = [p for p in tracked if p.endswith('.md')]


def strip_code(text):
    """去掉围栏代码块与行内代码；示例代码里的 [x](y) 不是链接。"""
    out = []
    fence = None
    for line in text.split('\n'):
        m = re.match(r'^\s*(' + BT + r'{3,}|~{3,})', line)
        if fence is not None:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence):
                fence = None
            out.append('')
            continue
        if m:
            fence = m.group(1)
            out.append('')
            continue
        out.append(line)
    body = '\n'.join(out)
    return re.sub(BT + r'[^' + BT + r']*' + BT, '', body)


fail = False
if len(md_files) < 60:
    print('    FAIL 只扫到 %d 个 .md（<60），疑似扫描面失效' % len(md_files))
    fail = True

problems = []
link_n = 0
for path in md_files:
    try:
        text = open(path, encoding='utf-8').read()
    except (OSError, UnicodeDecodeError) as exc:
        problems.append((path, 'read error: %s' % exc))
        continue
    for m in LINK.finditer(strip_code(text)):
        url = m.group(3).strip()
        link_n += 1
        if url.startswith('<') or url.endswith('>'):
            continue
        if SCHEME.match(url) or url.startswith('//') or url.startswith('#'):
            continue
        target = url.split('#', 1)[0]
        if not target:
            continue
        target = unquote(target)
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
        if resolved not in tracked_set:
            problems.append((path, '链接目标不是 tracked 文件：%s' % url))
        elif not os.path.isfile(resolved):
            problems.append((path, '链接目标不在工作树：%s' % url))

if len(md_files) >= 60 and link_n < 100:
    print('    FAIL 只解析到 %d 个相对链接（<100），疑似扫描面失效' % link_n)
    fail = True
if problems:
    fail = True
    for path, why in problems:
        print('    FAIL %s：%s' % (path, why))

if fail:
    sys.exit(1)
print('    ok    %d 个 .md / %d 个相对链接全部解析到 tracked 文件' % (len(md_files), link_n))
PY_C
then
  echo "    PASS"
else
  echo "    FAIL"
  FAIL=1
fi

# ===== [d] 本地化表安全 =====
echo "[d] 本地化表安全（en / zh-Hans Localizable.strings）"
if python3 - <<'PY_D'
import re
import sys
from collections import Counter

FILES = {
    'en': 'desktop/native/gather-app/Sources/GatherUI/Resources/en.lproj/Localizable.strings',
    'zh-Hans': 'desktop/native/gather-app/Sources/GatherUI/Resources/zh-Hans.lproj/Localizable.strings',
}
# printf 占位符：不看 %%；孤立的 %（非合法转换）按字面文本处理，不做占位符。
# 空格 flag（% a）故意不收：英文文案里的 100% at / 2% and 是字面百分号，不是格式串。
PLACEHOLDER = re.compile(
    r"%(?:\d+\$)?[-+#0']*(?:\*|\d+)?(?:\.(?:\*|\d+))?"
    r"(?:hh|h|ll|l|q|L|z|t|j)?[diouxXeEfFgGaAcCsSpn@]"
)
CJK = re.compile(
    '[\u2e80-\u2fff\u3000-\u303f\u3040-\u30ff\u3400-\u4dbf'
    '\u4e00-\u9fff\uf900-\ufaff\ufe30-\ufe4f\uff00-\uffef]'
)


def tokens(text):
    out = []
    i = 0
    while i < len(text):
        if text[i] != '%':
            i += 1
            continue
        if i + 1 < len(text) and text[i + 1] == '%':
            i += 2
            continue
        m = PLACEHOLDER.match(text, i)
        if m:
            out.append(m.group(0))
            i = m.end()
        else:
            i += 1
    return out


def parse_strings(path):
    """完整解析 .strings（行注释 / 块注释 / 转义引号），返回 (entries, errors)。"""
    text = open(path, encoding='utf-8').read()
    n = len(text)
    entries = []
    errors = []
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
        assert text[state['i']] == '"'
        state['i'] += 1
        buf = []
        while state['i'] < n:
            c = text[state['i']]
            if c == '\\':
                if state['i'] + 1 >= n:
                    break
                esc = text[state['i'] + 1]
                buf.append({'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\', "'": "'"}.get(esc, '\\' + esc))
                state['i'] += 2
            elif c == '"':
                state['i'] += 1
                return ''.join(buf)
            else:
                if c == '\n':
                    state['line'] += 1
                buf.append(c)
                state['i'] += 1
        raise ValueError('字符串未闭合')

    while True:
        skip_ws_comments()
        if state['i'] >= n:
            break
        entry_line = state['line']
        try:
            key = read_quoted()
            skip_ws_comments()
            if state['i'] >= n or text[state['i']] != '=':
                raise ValueError('缺 =')
            state['i'] += 1
            skip_ws_comments()
            value = read_quoted()
            skip_ws_comments()
            if state['i'] >= n or text[state['i']] != ';':
                raise ValueError('缺 ;')
            state['i'] += 1
            entries.append((entry_line, key, value))
        except ValueError as exc:
            errors.append((entry_line, str(exc)))
            break
    return entries, errors


fail = False
for lang, path in FILES.items():
    try:
        entries, errors = parse_strings(path)
    except (OSError, UnicodeDecodeError) as exc:
        print('    FAIL %s：无法读取 %s（%s）' % (lang, path, exc))
        fail = True
        continue

    min_entries = 2000 if lang == 'en' else 5
    if len(entries) < min_entries:
        print('    FAIL %s：只解析到 %d 条（<%d），疑似解析器/文件异常' % (lang, len(entries), min_entries))
        fail = True

    lang_bad = False
    for line, why in errors:
        print('    FAIL %s L%d：条目结构非法（%s）' % (lang, line, why))
        lang_bad = True
    seen = {}
    for line, key, value in entries:
        if key in seen:
            print('    FAIL %s L%d：重复 key %r（首次出现 L%d）' % (lang, line, key, seen[key]))
            lang_bad = True
        else:
            seen[key] = line
    for line, key, value in entries:
        if not value.strip():
            print('    FAIL %s L%d：空 value %r' % (lang, line, key))
            lang_bad = True
        if lang == 'en' and CJK.search(value):
            print('    FAIL %s L%d：en value 含 CJK %r' % (lang, line, value))
            lang_bad = True
        tk = tokens(key)
        tv = tokens(value)
        if Counter(tk) != Counter(tv):
            print('    FAIL %s L%d：printf 占位符不一致 key=%r value=%r（key %s / value %s）'
                  % (lang, line, key, value, tk, tv))
            lang_bad = True

    token_n = sum(len(tokens(key)) for _, key, _ in entries)
    if lang == 'en' and token_n < 300:
        print('    FAIL %s：只比对到 %d 个占位符 token（<300），疑似解析器失效' % (lang, token_n))
        lang_bad = True
    if lang_bad:
        fail = True
        continue
    print('    ok    %s：%d 条 key；0 重复 / 0 空值%s / 0 占位符不一致（比对 %d 个 token）'
          % (lang, len(entries), ' / 0 CJK 值' if lang == 'en' else '', token_n))

sys.exit(1 if fail else 0)
PY_D
then
  echo "    PASS"
else
  echo "    FAIL"
  FAIL=1
fi

# ===== [e] scripts/ 无提交的缓存/构建产物 =====
echo "[e] scripts/ 无提交的缓存/构建产物"
E_BAD=0
E_N=0
while IFS= read -r -d '' f; do
  case "$f" in
    scripts/*) ;;
    *) continue ;;
  esac
  E_N=$((E_N + 1))
  case "$f" in
    */__pycache__/*|*/__pycache__|*.pyc|*.pyo|*/.build/*|*/build/*|*.o|*.a|*.dylib|*.dSYM/*)
      echo "    FAIL scripts/ 下有提交的缓存/构建产物：$f"
      E_BAD=1
      ;;
  esac
done < <(git ls-files -z)
if [ "$E_N" -lt 10 ]; then
  echo "    FAIL scripts/ 只扫到 $E_N 个 tracked 文件（<10），疑似路径/检出异常"
  E_BAD=1
fi
if [ "$E_BAD" -eq 0 ]; then
  echo "    ok    scripts/ tracked 文件 $E_N 个，0 个缓存/构建产物"
  echo "    PASS"
else
  echo "    FAIL"
  FAIL=1
fi

# ===== [f] shellcheck（tracked *.sh，severity warning） =====
echo "[f] shellcheck（tracked *.sh，severity warning）"
F_BAD=0
F_N=0
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "    FAIL 缺少 shellcheck（CI ubuntu-latest 预装；本地：apt-get install shellcheck 或 brew install shellcheck）"
  echo '          本机也可用 gitignored 的 .gather/shellcheck：PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh'
  F_BAD=1
else
  SC_VERSION="$(shellcheck --version | awk '/^version: / { print $2; exit }')"
  SH_FILES=()
  # tracked *.sh（含 desktop/native/build.sh）；git ls-files 已按路径排序，输出确定。
  while IFS= read -r -d '' f; do
    SH_FILES+=("$f")
  done < <(git ls-files -z -- '*.sh')
  F_N="${#SH_FILES[@]}"
  if [ "$F_N" -lt 15 ]; then
    echo "    FAIL 只扫到 $F_N 个 tracked *.sh（<15），疑似路径/检出异常"
    F_BAD=1
  else
    F_OUT="$SCRATCH/shellcheck.out"
    F_RC=0
    # 清掉 SHELLCHECK_OPTS：[f] 的规则集必须固定，不能被本机环境变量（如 -e SCxxxx）放宽。
    unset SHELLCHECK_OPTS
    shellcheck -S warning -f gcc "${SH_FILES[@]}" > "$F_OUT" 2>&1 || F_RC=$?
    if [ "$F_RC" -eq 0 ]; then
      echo "    ok    shellcheck $SC_VERSION：$F_N 个 tracked *.sh，0 finding"
    else
      F_FINDINGS="$(grep -cE '^[^:]+:[0-9]+:[0-9]+:' "$F_OUT" 2>/dev/null || true)"
      echo "    FAIL shellcheck $SC_VERSION：$F_FINDINGS 条 finding（退出码 $F_RC）"
      if [ -s "$F_OUT" ]; then
        sed 's/^/    FAIL /' "$F_OUT"
      else
        echo "    FAIL shellcheck 无诊断输出但退出码非 0（疑似工具异常）"
      fi
      F_BAD=1
    fi
  fi
fi
if [ "$F_BAD" -eq 0 ]; then
  echo "    PASS"
else
  echo "    FAIL"
  FAIL=1
fi

echo "----"
if [ "$FAIL" -ne 0 ]; then
  echo "check-repo-hygiene: FAILED（修完上方 FAIL 项后重跑）"
  exit 1
fi
echo "check-repo-hygiene: OK"
