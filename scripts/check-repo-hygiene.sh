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
#   [b] .editorconfig 一致性（tracked 文本文件：swift/md/sh/py/json/yml/yaml/strings/txt
#       + plist/entitlements/modulemap/h/c/tsv/pbxproj/xcconfig/m/mm；basename 另含
#       Makefile/LICENSE/SHA256SUMS/.gitignore；再加 .editorconfig / .gitattributes）
#       - end_of_line=lf；trim_trailing_whitespace（含纯空白行）；insert_final_newline；charset=utf-8
#         （UTF-8 BOM 判 FAIL）。
#   [c] Markdown 相对链接
#       - tracked *.md 中 [x](path)、![x](path)、带 title 的 [x](path "t")、引用式
#         [x][ref] + [ref]: path 都必须解析到 tracked 文件（CI checkout 里也存在）；
#       - 跳过 http(s)/mailto/其它 scheme、#锚点、协议相对 //、尖括号形式、未定义引用；
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
#   [g] 本地化用法（GatherUI 的 UI 文案）
#       - Sources/GatherUI/**/*.swift 中传给 UI API（Text/Label/Button/Toggle/Picker/
#         Section/LabeledContent/.help/accessibilityLabel/accessibilityHint/navigationTitle/
#         alert/confirmationDialog 等）的 CJK 字符串字面量，必须位于本地化包装
#         （l10n(...) / l(...) / LocalizedText(...) / CullingNotice / FaceNotice /
#         SimilarityNotice / CommandError.localized / …）内部；否则 FAIL 并打印 file:line。
#       - 平衡括号解析多行调用；跳过注释、#Preview 块和 PreviewSupport/ 预览夹具目录
#         （那里的中文是示例数据，不是产品文案）。
#   [h] SwiftPM 包集合
#       - `git ls-files '*Package.swift'` 必须恰为 desktop/native/gather-core/Package.swift
#         与 desktop/native/gather-app/Package.swift 两个；多一个或少于两个都 FAIL。
#       - 动机：所有门禁/CI 都硬编码这两个包路径，新增第三个 SwiftPM 包既不会被扫描、
#         也不会被编译（2026-11-23 P1-3，见 .tmp/arch-plan-2026-11-23/06-gates.md §6.3）。
#       - --self-test 只跑本节的合成样本（正样本 / 第三个包 / 缺包），不需要 git 检出。
#
# 防「静默 0 命中」守卫：每个检查面都有扫描量下限（文件数 / 链接数 / key 数 / 占位符数），
# 低于下限直接 FAIL，避免路径或解析器失效时门禁变绿。
#
# 用法：./scripts/check-repo-hygiene.sh [--self-test]
# exit 0 = 八节全过；exit 1 = 至少一节失败（消息含节名与文件行号）。
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

if ! python3 - "$SCRATCH" "$@" <<'PY_HYGIENE'
# check-repo-hygiene 的检查内核：八节合并为单进程，git ls-files 与文件读取各一次。
# 由 scripts/check-repo-hygiene.sh 通过 heredoc 调用，输出行格式与逐节旧实现逐字节一致。
# 参数：argv[1] = 临时目录（SCRATCH），用于 py_compile 字节码与 shellcheck 输出；
#       argv[2:] = 脚本参数（目前只支持 --self-test：只跑 [h] 的合成样本）。
import contextlib
import io
import os
import py_compile
import re
import shutil
import subprocess
import sys
import traceback

SCRATCH = sys.argv[1]
ARGS = sys.argv[2:]
SELFTEST = '--self-test' in ARGS
UNKNOWN_ARGS = [arg for arg in ARGS if arg != '--self-test']
FAIL = False

# ---- 共用：一次 git ls-files；文件内容按需缓存，一次读盘复用给多节 ----
if SELFTEST:
    tracked = []  # --self-test 只跑 [h] 的合成样本，不依赖 git 检出
else:
    tracked = subprocess.check_output(['git', 'ls-files', '-z']).split(b'\0')
    tracked = sorted(p.decode('utf-8', 'surrogateescape') for p in tracked if p)
# 空 tracked：与旧实现一致——[a] 打印 FAIL 并结束本节，其余节仍按空清单继续检查。
TRACKED_EMPTY = not tracked

BYTES = {}
HEAD2 = {}
READ_ERRORS = {}


def read_bytes(path):
    if path in BYTES:
        return BYTES[path]
    if path in READ_ERRORS:
        return None
    try:
        with open(path, 'rb') as fh:
            data = fh.read()
    except OSError as exc:
        READ_ERRORS[path] = exc
        return None
    BYTES[path] = data
    return data


def read_head2(path):
    """只读前 2 字节（shebang 判定），避免为 1,200 个文件整读。"""
    if path in HEAD2:
        return HEAD2[path]
    try:
        with open(path, 'rb') as fh:
            head = fh.read(2)
    except OSError as exc:
        READ_ERRORS[path] = exc
        return None
    HEAD2[path] = head
    return head


def read_text(path):
    data = read_bytes(path)
    if data is None:
        return None
    return data.decode('utf-8')


def dump(text):
    for line in text.splitlines():
        print('        ' + line)


def run_section(header, func):
    """打印节标题；节内异常与旧实现一致：traceback 到 stderr、本节 FAIL、后续节继续。"""
    print(header)
    try:
        ok = func()
    except Exception:
        traceback.print_exc()
        ok = False
    print('    PASS' if ok else '    FAIL')
    return ok


# ===== [a] 脚本语法 / shebang 执行位 / CRLF =====
def section_a():
    fail = False
    if TRACKED_EMPTY:
        print('    FAIL git ls-files 返回 0 个 tracked 文件，疑似不在 git 检出内')
        return False
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

    py_files = [p for p in tracked if p.startswith('scripts/') and p.endswith('.py')]
    py_bad = []
    if len(py_files) < 2:
        print('    FAIL 只扫到 %d 个 scripts/**/*.py（<2），疑似 git 路径/检出异常' % len(py_files))
        fail = True
    env = dict(os.environ)
    env['PYTHONPYCACHEPREFIX'] = os.path.join(SCRATCH, 'pycache')
    pycache_dir = os.path.join(SCRATCH, 'pycache')
    os.makedirs(pycache_dir, exist_ok=True)
    pycfile = os.path.join(pycache_dir, 'verify.pyc')
    for path in py_files:
        ok = True
        stderr = ''
        try:
            py_compile.compile(path, cfile=pycfile, doraise=True)
        except Exception:
            # 失败时回退到子进程，保证与旧实现（python3 -m py_compile）的 stderr 逐字节一致。
            proc = subprocess.run(
                [sys.executable or 'python3', '-m', 'py_compile', path],
                capture_output=True, text=True, env=env)
            ok = proc.returncode == 0
            stderr = proc.stderr
        if not ok:
            print('    FAIL py_compile 失败：%s' % path)
            dump(stderr.strip())
            py_bad.append(path)
    if py_bad:
        fail = True
    else:
        print('    ok    py_compile：%d 个 scripts/**/*.py' % len(py_files))

    shebang_files = []
    for path in tracked:
        head = read_head2(path)
        if head is None:
            exc = READ_ERRORS[path]
            print('    FAIL 无法读取：%s（%s）' % (path, exc))
            fail = True
            continue
        if head == b'#!':
            shebang_files.append(path)
    shebang_bad = []
    if len(shebang_files) < 20:
        print('    FAIL 只扫到 %d 个 shebang 文件（<20），疑似扫描面失效' % len(shebang_files))
        fail = True
    for path in shebang_files:
        try:
            mode = os.stat(path).st_mode
        except OSError:
            mode = 0
        if not (mode & 0o111):
            print('    FAIL shebang 文件缺执行位：%s（chmod +x）' % path)
            shebang_bad.append(path)
    if shebang_bad:
        fail = True
    else:
        print('    ok    shebang 执行位：%d 个文件全部可执行' % len(shebang_files))

    crlf_bad = []
    for path in sh_files:
        data = read_bytes(path)
        if data is None:
            raise READ_ERRORS[path]
        if b'\r' in data:
            print('    FAIL .sh 含 CR（应仅 LF）：%s' % path)
            crlf_bad.append(path)
    if crlf_bad:
        fail = True
    else:
        print('    ok    .sh 无 CR：%d 个' % len(sh_files))
    return not fail


# ===== [b] .editorconfig 一致性（LF / 无行尾空白 / 末行换行 / UTF-8） =====
def section_b():
    TEXT_EXT = (
        '.swift', '.md', '.sh', '.py', '.json', '.yml', '.yaml', '.strings', '.txt',
        '.plist', '.entitlements', '.modulemap', '.h', '.c', '.tsv', '.pbxproj',
        '.xcconfig', '.m', '.mm',
    )
    TEXT_FILENAMES = ('Makefile', 'LICENSE', 'SHA256SUMS', '.gitignore')
    EDITORCONFIG = '.editorconfig'
    files = [p for p in tracked
             if p.endswith(TEXT_EXT)
             or p in (EDITORCONFIG, '.gitattributes')
             or p.rsplit('/', 1)[-1] in TEXT_FILENAMES]
    fail = False
    if len(files) < 1000:
        print('    FAIL 只扫到 %d 个文本文件（<1000），疑似扫描面失效' % len(files))
        fail = True
    if EDITORCONFIG not in files:
        print('    FAIL 缺少 %s' % EDITORCONFIG)
        fail = True
    problems = []
    for path in files:
        data = read_bytes(path)
        if data is None:
            problems.append((path, 'read error: %s' % READ_ERRORS[path]))
            continue
        if data.startswith(b'\xef\xbb\xbf'):
            problems.append((path, 'has UTF-8 BOM (charset=utf-8)'))
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
        m = re.search(r'[ \t](?=\n|$)', text)
        if m:
            no = text.count('\n', 0, m.start()) + 1
            problems.append((path, 'L%d trailing whitespace (trim_trailing_whitespace)' % no))
        if not text.endswith('\n'):
            problems.append((path, 'missing final newline (insert_final_newline)'))
    if problems:
        fail = True
        shown = problems[:40]
        for path, why in shown:
            print('    FAIL %s：%s' % (path, why))
        if len(problems) > len(shown):
            print('    FAIL ... 另有 %d 个文件不合规（合计 %d）'
                  % (len(problems) - len(shown), len(problems)))
    if fail:
        return False
    print('    ok    %d 个文本文件全部符合' % len(files))
    return True


# ===== [c] Markdown 相对链接 =====
def section_c():
    BT = chr(96)
    LINK = re.compile(r'(!?)\[([^\]]*)\]\(\s*(<[^>]*>|[^()\s]*(?:\([^()]*\))?[^()\s]*)(?:\s+"[^"]*")?\s*\)')
    REF_USE = re.compile(r'!?\[([^\]]+)\]\[([^\]]*)\]')
    REF_DEF = re.compile(r'^\s{0,3}\[([^\]]+)\]:\s*(\S+)')
    SCHEME = re.compile(r'^[A-Za-z][A-Za-z0-9+.-]*:')
    from urllib.parse import unquote

    tracked_set = set(tracked)
    md_files = [p for p in tracked if p.endswith('.md')]

    def strip_code(text):
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
    if len(md_files) < 10:
        print('    FAIL 只扫到 %d 个 .md（<10），疑似扫描面失效' % len(md_files))
        fail = True
    problems = []
    link_n = 0
    for path in md_files:
        text = read_text(path)
        if text is None:
            problems.append((path, 'read error: %s' % READ_ERRORS[path]))
            continue
        clean = strip_code(text)
        defs = {}
        for line in clean.split('\n'):
            dm = REF_DEF.match(line)
            if dm:
                defs[dm.group(1).lower()] = dm.group(2)

        def check_url(url):
            nonlocal link_n
            link_n += 1
            if url.startswith('<') and url.endswith('>'):
                url = url[1:-1]
            if SCHEME.match(url) or url.startswith('//') or url.startswith('#'):
                return
            target = url.split('#', 1)[0]
            if not target:
                return
            target = unquote(target)
            resolved = os.path.normpath(os.path.join(os.path.dirname(path), target))
            if resolved not in tracked_set:
                problems.append((path, '链接目标不是 tracked 文件：%s' % url))
            elif not os.path.isfile(resolved):
                problems.append((path, '链接目标不在工作树：%s' % url))

        for m in LINK.finditer(clean):
            check_url(m.group(3).strip())
        for m in REF_USE.finditer(clean):
            label = (m.group(2) or m.group(1)).lower()
            url = defs.get(label)
            if url is not None:
                check_url(url)

    if len(md_files) >= 10 and link_n < 10:
        print('    FAIL 只解析到 %d 个相对链接（<10），疑似扫描面失效' % link_n)
        fail = True
    if problems:
        fail = True
        for path, why in problems:
            print('    FAIL %s：%s' % (path, why))
    if fail:
        return False
    print('    ok    %d 个 .md / %d 个相对链接全部解析到 tracked 文件' % (len(md_files), link_n))
    return True


# ===== [d] 本地化表安全（en / zh-Hans Localizable.strings） =====
def section_d():
    from collections import Counter
    FILES = {
        'en': 'desktop/native/gather-app/Sources/GatherUI/Resources/en.lproj/Localizable.strings',
        'zh-Hans': 'desktop/native/gather-app/Sources/GatherUI/Resources/zh-Hans.lproj/Localizable.strings',
    }
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
        text = read_text(path)
        if text is None:
            raise READ_ERRORS[path]
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
                    buf.append({'n': '\n', 't': '\t', 'r': '\r', '"': '"',
                                '\\': '\\', "'": "'"}.get(esc, '\\' + esc))
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
        data = read_bytes(path)
        if data is None:
            print('    FAIL %s：无法读取 %s（%s）' % (lang, path, READ_ERRORS[path]))
            fail = True
            continue
        try:
            entries, errors = parse_strings(path)
        except UnicodeDecodeError as exc:
            print('    FAIL %s：无法读取 %s（%s）' % (lang, path, exc))
            fail = True
            continue

        min_entries = 2000 if lang == 'en' else 5
        if len(entries) < min_entries:
            print('    FAIL %s：只解析到 %d 条（<%d），疑似解析器/文件异常'
                  % (lang, len(entries), min_entries))
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
            print('    FAIL %s：只比对到 %d 个占位符 token（<300），疑似解析器失效'
                  % (lang, token_n))
            lang_bad = True
        if lang_bad:
            fail = True
            continue
        print('    ok    %s：%d 条 key；0 重复 / 0 空值%s / 0 占位符不一致（比对 %d 个 token）'
              % (lang, len(entries), ' / 0 CJK 值' if lang == 'en' else '', token_n))

    return not fail


# ===== [e] scripts/ 无提交的缓存/构建产物 =====
def section_e():
    bad = 0
    n = 0
    for path in tracked:
        if not path.startswith('scripts/'):
            continue
        n += 1
        if (re.search(r'(^|/)__pycache__(/|$)', path) or path.endswith('.pyc')
                or path.endswith('.pyo') or path.endswith('.o') or path.endswith('.a')
                or path.endswith('.dylib') or '/.build/' in path or '/build/' in path
                or '.dSYM/' in path):
            print('    FAIL scripts/ 下有提交的缓存/构建产物：%s' % path)
            bad = 1
    if n < 10:
        print('    FAIL scripts/ 只扫到 %d 个 tracked 文件（<10），疑似路径/检出异常' % n)
        bad = 1
    if bad == 0:
        print('    ok    scripts/ tracked 文件 %d 个，0 个缓存/构建产物' % n)
        return True
    return False


# ===== [f] shellcheck（tracked *.sh，severity warning） =====
SHELLCHECK_STATE = None


def shellcheck_launch():
    """提前启动 shellcheck 分片：[a]–[e]/[g] 计算期间 shellcheck 已在其它核上跑。"""
    global SHELLCHECK_STATE
    if shutil.which('shellcheck') is None:
        SHELLCHECK_STATE = None
        return None
    version_out = subprocess.run(['shellcheck', '--version'], capture_output=True, text=True).stdout
    sc_version = ''
    for line in version_out.splitlines():
        if line.startswith('version: '):
            sc_version = line[len('version: '):].split()[0]
            break
    sh_files = [p for p in tracked if p.endswith('.sh')]
    state = {'version': sc_version, 'files': sh_files, 'procs': [], 'out_paths': [],
             'rcs': {}, 'fallback': False, 'out_lines': None, 'rc': 0}
    SHELLCHECK_STATE = state
    if len(sh_files) < 15:
        return state
    env = dict(os.environ)
    # 清掉 SHELLCHECK_OPTS：[f] 的规则集必须固定，不能被本机环境变量（如 -e SCxxxx）放宽。
    env.pop('SHELLCHECK_OPTS', None)
    state['env'] = env
    # 并行分片：shellcheck 单进程要 1.1s+（build.sh 单文件 ~0.36s），按文件大小贪心分片
    # 到多进程可压到 ~0.4s；输出按 (文件顺序, 行, 列) 归一化，与单进程输出逐字节一致。
    jobs = min(8, max(2, os.cpu_count() or 4), len(sh_files))
    buckets = [[] for _ in range(jobs)]
    loads = [0] * jobs
    sized = [(os.path.getsize(path), index, path) for index, path in enumerate(sh_files)]
    for size, index, path in sorted(sized, reverse=True):
        b = loads.index(min(loads))
        buckets[b].append((index, path))
        loads[b] += size
    for b, bucket in enumerate(buckets):
        bucket.sort()
        out_path = os.path.join(SCRATCH, 'shellcheck.%d.out' % b)
        state['out_paths'].append(out_path)
        with open(out_path, 'wb') as fh:
            proc = subprocess.Popen(
                ['shellcheck', '-S', 'warning', '-f', 'gcc'] + [item[1] for item in bucket],
                stdout=fh, stderr=fh, env=env)
        state['procs'].append((proc, b))
    return state


def section_f():
    state = SHELLCHECK_STATE
    if state is None and shutil.which('shellcheck') is None:
        print('    FAIL 缺少 shellcheck（CI ubuntu-latest 预装；本地：apt-get install shellcheck 或 brew install shellcheck）')
        print('          本机也可用 gitignored 的 .gather/shellcheck：PATH="$PWD/.gather:$PATH" ./scripts/check-repo-hygiene.sh')
        return False
    if state is None:
        state = shellcheck_launch()
    sc_version = state['version']
    sh_files = state['files']
    f_n = len(sh_files)
    if f_n < 15:
        print('    FAIL 只扫到 %d 个 tracked *.sh（<15），疑似路径/检出异常' % f_n)
        return False
    for proc, b in state['procs']:
        state['rcs'][b] = proc.wait()
    env = state['env']
    order = {path: index for index, path in enumerate(sh_files)}
    merged = []
    fallback = False
    for out_path in state['out_paths']:
        with open(out_path, 'rb') as fh:
            raw = fh.read()
        for line in raw.decode('utf-8', 'surrogateescape').split('\n'):
            if not line:
                continue
            parts = line.split(':', 3)
            if (len(parts) < 3 or parts[0] not in order
                    or not parts[1].isdigit() or not parts[2].isdigit()):
                fallback = True
                break
            merged.append((order[parts[0]], int(parts[1]), int(parts[2]), line))
        if fallback:
            break
    rc_values = [value for value in state['rcs'].values() if value != 0]
    rc = rc_values[0] if rc_values else 0
    if fallback or any(value not in (0, 1) for value in state['rcs'].values()):
        # 极端情况（无法解析/异常退出码）：回退单进程调用，保证与旧实现逐字节一致。
        out_path = os.path.join(SCRATCH, 'shellcheck.out')
        with open(out_path, 'wb') as fh:
            rc = subprocess.run(['shellcheck', '-S', 'warning', '-f', 'gcc'] + sh_files,
                                stdout=fh, stderr=fh, env=env).returncode
        with open(out_path, 'rb') as fh:
            out_lines = [line for line in fh.read().decode('utf-8', 'surrogateescape').split('\n')
                         if line]
    else:
        merged.sort()
        out_lines = [line for _, _, _, line in merged]
    if rc == 0:
        print('    ok    shellcheck %s：%d 个 tracked *.sh，0 finding' % (sc_version, f_n))
        return True
    findings = len(re.findall(r'^[^:]+:[0-9]+:[0-9]+:', '\n'.join(out_lines), re.M))
    print('    FAIL shellcheck %s：%d 条 finding（退出码 %d）' % (sc_version, findings, rc))
    if out_lines:
        for line in out_lines:
            print('    FAIL ' + line)
    else:
        print('    FAIL shellcheck 无诊断输出但退出码非 0（疑似工具异常）')
    return False


# ===== [g] 本地化用法（UI 文案 CJK 字面量必须走 l10n/LocalizedText/…） =====
def section_g():
    from pathlib import Path
    ROOT = Path.cwd()
    UI = ROOT / 'desktop' / 'native' / 'gather-app' / 'Sources' / 'GatherUI'
    CJK = re.compile('[\u2e80-\u2fff\u3000-\u303f\u3040-\u30ff\u3400-\u4dbf'
                     '\u4e00-\u9fff\uf900-\ufaff\ufe30-\ufe4f\uff00-\uffef]')
    UI_APIS = {
        'Text', 'Label', 'Button', 'Toggle', 'Picker', 'Section', 'NavigationLink', 'Menu',
        'Stepper', 'TextField', 'SecureField', 'TextEditor', 'ProgressView', 'GroupBox',
        'DisclosureGroup', 'Link', 'TabView', 'LabeledContent', 'ContentUnavailableView',
        'Gauge', 'ColorPicker', 'Slider', 'DatePicker', 'Table', 'ControlGroup',
        'help', 'accessibilityLabel', 'accessibilityHint', 'accessibilityValue',
        'navigationTitle', 'navigationSubtitle', 'alert', 'confirmationDialog',
        'badge', 'sheet', 'popover',
    }
    WRAPPER_LAST = {'l', 'l10n', 'LocalizedText', 'CullingNotice', 'FaceNotice',
                    'SimilarityNotice', 'ErrorPresentation', 'DeliveryErrorPresentation',
                    'APIErrorPresentation'}
    WRAPPER_CHAIN = {'CommandError.localized'}
    WRAPPER_PREFIX = {'l10n'}
    IDENT_START = re.compile(r'[A-Za-z_$\u00a1-\uffff]')
    IDENT_RE = re.compile(r'[A-Za-z0-9_$\u00a1-\uffff]+')
    TOK_IDENT, TOK_STRING, TOK_PUNCT = 'ident', 'string', 'punct'

    def tokenize(text):
        toks = []
        n = len(text)
        i = 0
        line = 1

        def skip_block_comment(i):
            depth = 0
            while i < n:
                if text.startswith('/*', i):
                    depth += 1
                    i += 2
                    continue
                if text.startswith('*/', i):
                    depth -= 1
                    i += 2
                    if depth == 0:
                        return i
                    continue
                i += 1
            return n

        def skip_interpolation(i):
            depth = 1
            while i < n:
                if text.startswith('//', i):
                    j = text.find('\n', i)
                    i = n if j < 0 else j
                    continue
                if text.startswith('/*', i):
                    i = skip_block_comment(i)
                    continue
                if text[i] == '"':
                    i, _ = skip_string(i)
                    continue
                if text[i] == '(':
                    depth += 1
                elif text[i] == ')':
                    depth -= 1
                    if depth == 0:
                        return i + 1
                i += 1
            return n

        def skip_string(i):
            nonlocal line
            multi = text.startswith('"""', i)
            i += 3 if multi else 1
            parts = []
            while i < n:
                c = text[i]
                if c == '\n':
                    line += 1
                    if not multi:
                        break
                    parts.append('\n')
                    i += 1
                    continue
                if c == '\\':
                    if i + 1 < n and text[i + 1] == '(':
                        i = skip_interpolation(i + 2)
                        continue
                    if i + 1 < n:
                        parts.append({'n': '\n', 't': '\t', 'r': '\r', '\\': '\\',
                                      '"': '"', "'": "'"}.get(text[i + 1], text[i + 1]))
                        i += 2
                        continue
                    i += 1
                    continue
                if multi:
                    if text.startswith('"""', i):
                        return i + 3, ''.join(parts)
                elif c == '"':
                    return i + 1, ''.join(parts)
                parts.append(c)
                i += 1
            return i, ''.join(parts)

        while i < n:
            c = text[i]
            if c == '\n':
                line += 1
                i += 1
            elif c in ' \t\r':
                i += 1
            elif text.startswith('//', i):
                j = text.find('\n', i)
                i = n if j < 0 else j
            elif text.startswith('/*', i):
                i = skip_block_comment(i)
            elif c == '"':
                start_line = line
                j, parts = skip_string(i)
                toks.append((TOK_STRING, parts, start_line, i))
                i = j
            elif c == '#':
                toks.append((TOK_PUNCT, '#', line, i))
                i += 1
            elif IDENT_START.match(c):
                m = IDENT_RE.match(text, i)
                toks.append((TOK_IDENT, m.group(0), line, i))
                i = m.end()
            else:
                toks.append((TOK_PUNCT, c, line, i))
                i += 1
        return toks

    OPEN = {'(': ')', '[': ']', '{': '}'}
    CLOSE = {v: k for k, v in OPEN.items()}

    def chain_before(toks, idx):
        parts = []
        j = idx - 1
        if j < 0 or toks[j][0] != TOK_IDENT:
            return ''
        parts.append(toks[j][1])
        j -= 1
        while j >= 1 and toks[j][1] == '.' and toks[j - 1][0] == TOK_IDENT:
            parts.append(toks[j - 1][1])
            j -= 2
        return '.'.join(reversed(parts))

    def is_wrapper(chain):
        if not chain:
            return False
        if chain in WRAPPER_CHAIN:
            return True
        first = chain.split('.')[0]
        last = chain.split('.')[-1]
        return first in WRAPPER_PREFIX or last in WRAPPER_LAST

    def ui_match(chain):
        if not chain:
            return None
        last = chain.split('.')[-1]
        return last if last in UI_APIS else None

    def file_text(path):
        spath = str(path)
        text = BYTES.get(spath)
        if text is not None:
            return text.decode('utf-8')
        with open(path, 'rb') as fh:
            return fh.read().decode('utf-8')

    def analyze(path):
        text = file_text(path)
        toks = tokenize(text)
        n = len(toks)
        stack, frames, frame_at = [], {}, [None] * n
        serial = 0
        for i, (kind, val, ln, pos) in enumerate(toks):
            if kind == TOK_PUNCT and val in OPEN:
                serial += 1
                frames[serial] = {'serial': serial, 'open': i, 'close': None,
                                  'callee': chain_before(toks, i) if val == '(' else '',
                                  'parent': stack[-1]['serial'] if stack else None}
                frame_at[i] = serial
                stack.append(frames[serial])
            elif kind == TOK_PUNCT and val in CLOSE and stack:
                frame = stack.pop()
                frame['close'] = i
                frame_at[i] = frame['serial']
            else:
                frame_at[i] = stack[-1]['serial'] if stack else None

        preview = [False] * n
        k = 0
        while k < n - 1:
            if toks[k][1] == '#' and toks[k + 1][0] == TOK_IDENT and toks[k + 1][1] == 'Preview':
                j = k + 2
                while j < n and not (toks[j][0] == TOK_PUNCT and toks[j][1] == '{'):
                    j += 1
                if j < n and frame_at[j] is not None:
                    end = frames[frame_at[j]]['close']
                    if end is None:
                        end = n - 1
                    for x in range(k, end + 1):
                        preview[x] = True
                    k = end + 1
                    continue
            k += 1

        violations = []
        ui_calls = 0
        cjk_total = 0
        for serial, frame in frames.items():
            if frame['close'] is None:
                continue
            ui = ui_match(frame['callee'])
            if not ui:
                continue
            ui_calls += 1
            for i in range(frame['open'] + 1, frame['close']):
                if preview[i]:
                    continue
                kind, parts, ln, pos = toks[i]
                if kind != TOK_STRING or not CJK.search(parts):
                    continue
                cjk_total += 1
                chain = []
                s = frame_at[i]
                while s is not None:
                    chain.append(s)
                    s = frames[s]['parent']
                wrapped = False
                for sid in chain:
                    if sid == serial:
                        break
                    if is_wrapper(frames[sid]['callee']):
                        wrapped = True
                        break
                if not wrapped:
                    violations.append((str(path.relative_to(ROOT)), ln, ui, parts))
        return violations, ui_calls, cjk_total

    if not UI.is_dir():
        print('    FAIL 缺少 GatherUI 目录：%s' % UI)
        return False
    files = sorted(p for p in UI.rglob('*.swift') if 'PreviewSupport' not in p.parts)
    fail = False
    violations = []
    ui_calls = 0
    cjk_total = 0
    for path in files:
        try:
            found, calls, cjk = analyze(path)
        except (OSError, UnicodeDecodeError) as exc:
            print('    FAIL 无法解析 %s：%s' % (path.relative_to(ROOT), exc))
            fail = True
            continue
        violations.extend(found)
        ui_calls += calls
        cjk_total += cjk
    if len(files) < 200:
        print('    FAIL 只扫到 %d 个 GatherUI Swift 文件（<200），疑似扫描面失效' % len(files))
        fail = True
    if ui_calls < 300:
        print('    FAIL 只识别到 %d 处 UI 文案调用（<300），疑似解析器失效' % ui_calls)
        fail = True
    if cjk_total < 20:
        print('    FAIL 只发现 %d 个 UI 调用内的 CJK 字面量（<20），疑似解析器失效' % cjk_total)
        fail = True
    if violations:
        fail = True
        for path, line, api, parts in sorted(violations):
            text = parts.replace('\n', '\\n')
            print("    FAIL %s:%d  [%s] %r 未走本地化包装（改用 l10n(...)/LocalizedText(...)/"
                  "l10n.format(...) 组合）" % (path, line, api, text))
        print('    FAIL 未包裹 CJK 字面量 %d 处（共 %d 个 UI 调用内 CJK 字面量，已包裹 %d）'
              % (len(violations), cjk_total, cjk_total - len(violations)))
    if fail:
        return False
    print('    ok    %d 文件 / %d 处 UI 文案调用 / CJK 字面量 %d（全部已包裹）'
          % (len(files), ui_calls, cjk_total))
    return True


# ===== [h] SwiftPM 包集合（新增第三个包必须显式登记） =====
# 所有门禁/CI 都硬编码 gather-core + gather-app：新增第三个 SwiftPM 包既不会被扫描，
# 也不会被编译（2026-11-23 P1-3，见 .tmp/arch-plan-2026-11-23/06-gates.md §6.3）。
# 用 git ls-files 的权威集合断言「恰为这两个」，多一个或少一个都 FAIL。
PACKAGE_MANIFESTS = (
    'desktop/native/gather-core/Package.swift',
    'desktop/native/gather-app/Package.swift',
)


def package_set_problems(manifests):
    found = sorted(p for p in manifests if p.rsplit('/', 1)[-1] == 'Package.swift')
    problems = []
    if len(found) != len(PACKAGE_MANIFESTS):
        problems.append('Package.swift 应恰为 %d 个（%s），实际 %d 个：%s；'
                        '新增 SwiftPM 包必须同时纳入门禁与 CI'
                        % (len(PACKAGE_MANIFESTS), ' / '.join(PACKAGE_MANIFESTS),
                           len(found), ', '.join(found) or '(空)'))
    for expected in PACKAGE_MANIFESTS:
        if expected not in found:
            problems.append('缺少预期的包清单：%s' % expected)
    for extra in found:
        if extra not in PACKAGE_MANIFESTS:
            problems.append('未登记的 SwiftPM 包：%s' % extra)
    return problems


def section_h():
    problems = package_set_problems(tracked)
    if problems:
        for problem in problems:
            print('    FAIL ' + problem)
        return False
    print('    ok    %d 个 Package.swift（gather-core / gather-app），无未登记的新包'
          % len(PACKAGE_MANIFESTS))
    return True


def self_test_package_set():
    good = list(PACKAGE_MANIFESTS)
    extra = good + ['desktop/native/gather-tools/Package.swift']
    missing = good[:1]
    failures = []
    if package_set_problems(good):
        failures.append('正样本（2 个包）被误报')
    if not package_set_problems(extra):
        failures.append('第三个包未被发现')
    if not package_set_problems(missing):
        failures.append('缺包未被发现')
    if failures:
        for item in failures:
            print('    FAIL ' + item)
        return False
    print('    ok    self-test：2 包通过 / 第三个包 FAIL / 缺包 FAIL')
    return True


def main():
    global FAIL
    if UNKNOWN_ARGS:
        print('check-repo-hygiene: 未知参数：%s（只支持 --self-test）'
              % ' '.join(UNKNOWN_ARGS), file=sys.stderr)
        sys.exit(2)
    if SELFTEST:
        ok = run_section('[h] SwiftPM 包集合（--self-test 合成样本）', self_test_package_set)
        sys.exit(0 if ok else 1)
    sections_ae = (
        ('[a] 脚本语法 / shebang 执行位 / CRLF', section_a),
        ('[b] .editorconfig 一致性（LF / 无行尾空白 / 末行换行 / UTF-8）', section_b),
        ('[c] Markdown 相对链接', section_c),
        ('[d] 本地化表安全（en / zh-Hans Localizable.strings）', section_d),
        ('[e] scripts/ 无提交的缓存/构建产物', section_e),
    )
    # shellcheck 先启动，[a]–[e]/[g] 计算期间已在并行跑。
    shellcheck_launch()
    for header, func in sections_ae:
        if not run_section(header, func):
            FAIL = True
    # [g] 的计算与 shellcheck 收尾重叠；输出先缓冲，等 [f] 打印完再按原顺序输出。
    g_buf = io.StringIO()
    with contextlib.redirect_stdout(g_buf):
        ok_g = run_section('[g] 本地化用法（UI 文案 CJK 字面量必须走 l10n/LocalizedText/…）',
                           section_g)
    if not run_section('[f] shellcheck（tracked *.sh，severity warning）', section_f):
        FAIL = True
    sys.stdout.write(g_buf.getvalue())
    if not ok_g:
        FAIL = True
    if not run_section('[h] SwiftPM 包集合（git ls-files 恰为 2 个）', section_h):
        FAIL = True
    sys.exit(1 if FAIL else 0)


main()

PY_HYGIENE
then
  FAIL=1
fi

echo "----"
if [ "$FAIL" -ne 0 ]; then
  echo "check-repo-hygiene: FAILED（修完上方 FAIL 项后重跑）"
  exit 1
fi
echo "check-repo-hygiene: OK"
