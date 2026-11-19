#!/usr/bin/env bash
# 测试目录门禁（refactor-design-breaking-2026-10-21 §8.6 / §8.3）。
#
# 检查：
#   1. Tests 下每个 *.swift 是否有文件头注释（首个非空行以 // 开头）。
#   2. 统计 skip 站点：@Test/@Suite 的 .enabled(if:) / .disabled(...)、
#      行首 .disabled(...) / .enabled(if:...)、withKnownIssue(...)。
#   3. 每个 skip 站点必须带 owner、到期、原因（连续注释块内），缺失即列 file:line。
#   4. --self-test 用临时目录自测：缺元数据 exit 1，补齐后 exit 0。
#   5. ratchet：@Test/@Suite/断言只降不升，skip 站点只降不升；基线见
#      docs/baselines/test-catalog-baseline.json（schema 2；缺文件/缺 key → FAIL）。
#
# 当前以 warning 模式 exit 0；--strict 时存在缺口即 exit 1（CI 使用 --strict）。
# 注意：swift test 汇总行的 "N tests passed" 包含 skip；有效执行数 = 声明数 − skip 数。
# 用法：./scripts/check-test-catalog.sh [--strict] [--self-test]
#       ./scripts/check-test-catalog.sh --write-baseline [--allow-growth]
#   --write-baseline 只允许持平/收紧；确需扩张（含新增 skip 站点）必须同时给
#   --allow-growth 并在 docs/cleanup-backlog.md 台账记账；输出 schema=2 且不写
#   generated_at（重复写无 diff），同目录 mktemp + mv 原子替换。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export LC_ALL=en_US.UTF-8

# 3b-6：按 target 显式列根目录（不再用整个 Tests，避免将来新增的
# 非测试目录被误算）；GatherTestSupport 是 core 测试共享 fixture target，
# 同样需要文件头注释与禁用用例统计。
TEST_ROOTS=(
  "desktop/native/gather-core/Tests/GatherCoreTests"
  "desktop/native/gather-core/Tests/GatherTestSupport"
  "desktop/native/gather-app/Tests/GatherAppTests"
)

# 只允许 --self-test 的子进程覆盖扫描根，避免普通调用被环境变量绕过。
if [ "${CTC_SELF_TEST_CHILD:-0}" = "1" ] && [ -n "${CTC_TEST_ROOTS_OVERRIDE:-}" ]; then
  # shellcheck disable=SC2206  # 自测用空格分隔的测试根清单，有意按词拆分（SC2206 正是该语义）
  TEST_ROOTS=(${CTC_TEST_ROOTS_OVERRIDE})
fi

if [ "${CTC_SELF_TEST_CHILD:-0}" != "1" ]; then
  TEST_FILE_N=0
  for root in "${TEST_ROOTS[@]}"; do
    if [ ! -d "$root" ]; then
      echo "check-test-catalog: FAIL 缺少测试根：$root" >&2
      exit 1
    fi
    n=$(find "$root" -type f -name '*.swift' -not -path '*/.build/*' | wc -l | tr -d ' ')
    TEST_FILE_N=$((TEST_FILE_N + n))
  done
  if [ "$TEST_FILE_N" -lt 150 ]; then
    echo "check-test-catalog: FAIL 只扫到 ${TEST_FILE_N} 个测试文件（<150），疑似根路径错误" >&2
    exit 1
  fi
fi

STRICT=0
SELF_TEST=0
WRITE=0
ALLOW_GROWTH=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --self-test) SELF_TEST=1 ;;
    --write-baseline) WRITE=1 ;;
    --allow-growth) ALLOW_GROWTH=1 ;;
    -h|--help)
      sed -n '2,19p' "$0"
      exit 0
      ;;
    *)
      echo "check-test-catalog: 未知参数：$arg" >&2
      exit 2
      ;;
  esac
done

# 负例自测：临时目录内构造缺元数据 / 补齐元数据的 skip，验证 strict 开关是活的。
# 临时目录放脚本级变量：EXIT trap 在函数返回后才执行，local 变量届时已出作用域，
# 所以 trap 必须单引号延迟展开脚本级变量（立即展开只对 local 有效但会骗过 SC2064）。
SELFTEST_TMP=""
run_self_test() {
  local root script out rc
  # 共享计数 lib 负例自测（成功静默；失败即 self-test 失败）。
  python3 "$ROOT/scripts/lib/swift-counts.py" --self-test >/dev/null
  SELFTEST_TMP="$(mktemp -d)"
  trap 'rm -rf "$SELFTEST_TMP"' EXIT
  root="$SELFTEST_TMP/root"
  mkdir -p "$root"
  script="$ROOT/scripts/check-test-catalog.sh"

  cat > "$root/BadTest.swift" <<'SWIFT'
// self-test fixture
import Testing
struct BadTest {
    // 到期：2026-12-31
    // 原因：self-test
    @Test(.enabled(if: false))
    func skipped() {}
}
SWIFT

  cat > "$root/BadSuite.swift" <<'SWIFT'
// self-test fixture
import Testing
@Suite(.disabled("self-test"))
struct BadSuite {
    @Test func skipped() {}
}
SWIFT

  cat > "$root/BadDisabled.swift" <<'SWIFT'
// self-test fixture
import Testing
struct BadDisabled {
    @Test(.disabled("self-test"))
    func skipped() {}
}
SWIFT

  set +e
  out="$(CTC_SELF_TEST_CHILD=1 CTC_TEST_ROOTS_OVERRIDE="$root" "$script" --strict 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 1 ]; then
    echo "check-test-catalog: SELFTEST FAILED — 缺元数据 skip 应 exit 1，实际 $rc" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  case "$out" in
    *"BadTest.swift:6"*) ;;
    *) echo "check-test-catalog: SELFTEST FAILED — 未列出 BadTest.swift:6" >&2; printf '%s\n' "$out" >&2; return 1 ;;
  esac
  case "$out" in
    *"BadSuite.swift:3"*) ;;
    *) echo "check-test-catalog: SELFTEST FAILED — 未列出 BadSuite.swift:3" >&2; printf '%s\n' "$out" >&2; return 1 ;;
  esac
  case "$out" in
    *"BadDisabled.swift:4"*) ;;
    *) echo "check-test-catalog: SELFTEST FAILED — 未列出 BadDisabled.swift:4" >&2; printf '%s\n' "$out" >&2; return 1 ;;
  esac

  rm -f "$root/BadTest.swift" "$root/BadSuite.swift" "$root/BadDisabled.swift"
  cat > "$root/GoodSkip.swift" <<'SWIFT'
// self-test fixture
import Testing
// skip-owner: self-test
// 到期：2026-12-31
// 原因：self-test fixture
@Suite(.disabled("self-test"))
struct GoodSkip {
    // skip-owner: self-test
    // 到期：2026-12-31
    // 原因：self-test fixture
    @Test(.enabled(if: false))
    func skipped() {}
}
SWIFT

  set +e
  out="$(CTC_SELF_TEST_CHILD=1 CTC_TEST_ROOTS_OVERRIDE="$root" "$script" --strict 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "check-test-catalog: SELFTEST FAILED — 补齐元数据后应 exit 0，实际 $rc" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  case "$out" in
    *"skip 元数据缺失     0"*) ;;
    *) echo "check-test-catalog: SELFTEST FAILED — 补齐后仍报缺失" >&2; printf '%s\n' "$out" >&2; return 1 ;;
  esac

  echo "check-test-catalog: SELFTEST OK（缺元数据 exit 1；补齐 exit 0）"
}

if [ "$SELF_TEST" -eq 1 ]; then
  run_self_test
  exit $?
fi

# ===== 扫描（单趟读盘复用）=====
# 旧实现的热点：每个测试文件 1 次 awk 取文件头（336 次进程）、每个 skip 站点约 20 次
# sed 取上下文（17 站点 × ~20 次）、3 遍 grep 全量扫描、外加 1 次全量 Python 计数。
# 现在合并为 1 次 Python：读盘一遍并把文件内容留在内存里复用给所有检查面；
# 输出行格式、计数口径、扫描量下限与旧实现逐字节一致。
# ratchet 计数实现见 scripts/lib/swift-counts.py（与 report-baseline.sh 单一来源）。
TODAY="${CTC_TODAY:-$(date +%Y-%m-%d)}"
SCAN_TMP="$(mktemp -d)"
trap 'rm -rf "$SCAN_TMP"' EXIT
if ! python3 - "$SCAN_TMP" "$TODAY" "${TEST_ROOTS[@]}" <<'PY'
import importlib.util
import os
import re
import sys
from pathlib import Path

# 共享计数单一来源：scripts/lib/swift-counts.py（脚本已 cd 到仓库根）。
_SPEC = importlib.util.spec_from_file_location(
    'swift_counts', 'scripts/lib/swift-counts.py')
COUNTS = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(COUNTS)

outdir = sys.argv[1]
today = sys.argv[2]
roots = sys.argv[3:]

# 两个包的 Tests（ratchet 口径固定，不受 --self-test 的 CTC_TEST_ROOTS_OVERRIDE 影响）。
RATCHET_DIRS = [Path('desktop/native/gather-core/Tests'), Path('desktop/native/gather-app/Tests')]

# 与旧 grep 的 [[:space:]] 等价的行内空白（行内不会出现换行）。
SP = r'[ \t\r\v\f]'
G1 = re.compile(r'@(Test|Suite).*\.(disabled|enabled)' + SP + r'*\(')
G2 = re.compile(r'^' + SP + r'*\.(disabled|enabled)' + SP + r'*\(')
G3 = re.compile(r'withKnownIssue' + SP + r'*\(')
OWNER = re.compile(r'(^|[^A-Za-z])owner' + SP + r'*[:：]' + SP + r'*[^ \t\r\v\f]'
                   r'|负责人' + SP + r'*[:：]' + SP + r'*[^ \t\r\v\f]', re.I)
DUE = re.compile(r'到期|截止|skip-until' + SP + r'*[:：]|deadline' + SP + r'*[:：]')
REASON = re.compile(r'原因' + SP + r'*[:：]|reason' + SP + r'*[:：]'
                    r'|rationale' + SP + r'*[:：]', re.I)
DUE_LINE = re.compile(r'到期|截止|skip-until')
DATE = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2}')
FUNC = re.compile(r'func [A-Za-z_][A-Za-z0-9_]*')

# 文件内容缓存：每个文件只读盘/解码一次，供文件头、skip 站点、到期、ratchet 共用。
CACHE = {}


def read_text(path):
    if path in CACHE:
        return CACHE[path]
    try:
        with open(path, 'rb') as fh:
            text = fh.read().decode('utf-8', 'replace')
    except OSError:
        text = None
    CACHE[path] = text
    return text


def walk_swift(root, skip_build=False):
    """按 grep -r 的顺序（readdir 前序）遍历 *.swift；skip_build 对应 find 的 .build 排除。"""
    def visit(directory):
        try:
            entries = list(os.scandir(directory))
        except OSError:
            return
        for entry in entries:
            try:
                is_dir = entry.is_dir(follow_symlinks=False)
            except OSError:
                continue
            if is_dir:
                if skip_build and entry.name == '.build':
                    continue
                for item in visit(entry.path):
                    yield item
            elif entry.name.endswith('.swift'):
                yield entry.path
    for item in visit(root):
        yield item


# ---- 1) 文件头注释：find 可能含多个根，旧实现按路径全局排序后逐文件 awk 取首个非空行。
def first_nonblank_line(text):
    for line in text.split('\n'):
        if line and line.strip(' \t\r\v\f'):
            return line
    return None


total = 0
header_missing = 0
missing_header = []
header_files = []
for root in roots:
    header_files.extend(walk_swift(root, skip_build=True))
header_files.sort()
for path in header_files:
    total += 1
    text = read_text(path)
    first = first_nonblank_line(text) if text is not None else None
    if first is None or not first.startswith('//'):
        header_missing += 1
        missing_header.append(path)

# ---- 2) skip 站点：旧实现是 3 条 grep -rnE（@Test/@Suite trait、行首续行 trait、
#      withKnownIssue），取并集并按 (file,line) 去重；这里同序同口径复刻。
hits = []
seen = set()
for pattern in (G1, G2, G3):
    for root in roots:
        for path in walk_swift(root):
            text = read_text(path)
            if text is None:
                continue
            for lineno, line in enumerate(text.split('\n'), 1):
                if pattern.search(line):
                    key = '%s:%d' % (path, lineno)
                    if key in seen:
                        continue
                    seen.add(key)
                    hits.append((path, lineno, line))


def lines_of(path):
    text = read_text(path)
    return text.split('\n') if text is not None else []


def skip_metadata_missing(path, line, text):
    """复刻旧实现的「连续注释块 + 属性续行」向上回溯（最多 20 行）。"""
    lines = lines_of(path)
    ctx = [text]
    j = line - 1
    steps = 0
    while j >= 1 and steps < 20:
        raw = lines[j - 1] if j - 1 < len(lines) else ''
        trimmed = raw.strip(' \t\r\v\f')
        if not trimmed:
            break
        if trimmed.startswith('//') or trimmed.startswith('*') or trimmed.startswith('/*'):
            ctx.insert(0, raw)
        elif (trimmed.startswith('@Test') or trimmed.startswith('@Suite')
              or trimmed.startswith('#if') or trimmed.startswith('#elseif')
              or trimmed.startswith('#else') or trimmed.startswith('#endif')
              or trimmed.startswith('.') or trimmed.startswith(')')
              or trimmed.startswith('"')):
            ctx.insert(0, raw)
        else:
            break
        j -= 1
        steps += 1
    has_owner = any(OWNER.search(item) for item in ctx)
    has_due = any(DUE.search(item) for item in ctx)
    has_reason = any(REASON.search(item) for item in ctx)
    missing = []
    if not has_owner:
        missing.append('owner')
    if not has_due:
        missing.append('到期')
    if not has_reason:
        missing.append('原因')
    return '、'.join(missing)


def skip_test_name(path, line):
    lines = lines_of(path)
    for k in range(line, line + 13):
        if k - 1 >= len(lines):
            break
        m = FUNC.search(lines[k - 1])
        if m:
            return m.group(0)[len('func '):]
    return '(suite)'


skip_total = 0
enabled_n = 0
disabled_n = 0
known_n = 0
suite_n = 0
skip_missing_n = 0
warn_missing = []
for path, line, text in hits:
    trimmed = text.strip(' \t\r\v\f')
    # 跳过注释行（含 /// 文档注释与块注释 * 行），与旧脚本一致。
    if trimmed.startswith('//') or trimmed.startswith('*') or trimmed.startswith('/*'):
        continue
    skip_total += 1
    if 'withKnownIssue' in text:
        known_n += 1
    if '.enabled' in text:
        enabled_n += 1
    if '.disabled' in text:
        disabled_n += 1
    if '@Suite' in text:
        suite_n += 1
    missing = skip_metadata_missing(path, line, text)
    if not missing:
        continue
    tname = skip_test_name(path, line)
    skip_missing_n += 1
    warn_missing.append('  - %s:%d  test=%s（缺 %s）' % (path, line, tname, missing))

# ---- 3) 到期校验（复审 P2）：skip 的「到期：YYYY-MM-DD」过期即失败。
#      旧实现 sed -n "$((line-12)),$((line))p"：行号 <=12 时起始地址为 0/负数，
#      sed 直接报错（stderr 被吞）→ 无到期行；这里保留同一行为。
skip_expired_n = 0
warn_expired = []
for path, line, text in hits:
    if line <= 12:
        continue
    lines = lines_of(path)
    due_line = None
    for k in range(line - 12, line + 1):
        if k - 1 >= len(lines):
            break
        if DUE_LINE.search(lines[k - 1]):
            due_line = lines[k - 1]
    if due_line is None:
        continue
    dates = DATE.findall(due_line)
    if not dates:
        continue
    due = dates[-1]
    if due < today:
        skip_expired_n += 1
        warn_expired.append('  - %s:%d 到期=%s' % (path, line, due))


# ---- 4) 用例/套件/断言 ratchet：先剥注释再计数（注释里的 @Test/#expect 不是真声明）。
#      遮罩/计数口径唯一实现见 scripts/lib/swift-counts.py（与 report-baseline.sh 共享）；
#      loader 复用本脚本已读入的 CACHE，读盘仍是单趟（输出与旧内联实现逐字节一致）。
test_decl, suite_decl, assert_n = COUNTS.count_decls(
    RATCHET_DIRS, loader=lambda path: CACHE.get(str(path)))

counts = [total, header_missing, skip_total, enabled_n, disabled_n, known_n,
          suite_n, skip_missing_n, skip_expired_n, test_decl, suite_decl, assert_n]
with open(os.path.join(outdir, 'counts'), 'w', encoding='utf-8') as fh:
    fh.write(' '.join(str(value) for value in counts) + '\n')
with open(os.path.join(outdir, 'missing-header.txt'), 'w', encoding='utf-8') as fh:
    fh.write(''.join(path + '\n' for path in missing_header))
with open(os.path.join(outdir, 'warn-missing.txt'), 'w', encoding='utf-8') as fh:
    fh.write(''.join(line + '\n' for line in warn_missing))
with open(os.path.join(outdir, 'warn-expired.txt'), 'w', encoding='utf-8') as fh:
    fh.write(''.join(line + '\n' for line in warn_expired))
PY
then
  echo "check-test-catalog: FAIL 计数脚本没有输出（python3 可用？）" >&2
  exit 1
fi
read -r total header_missing skip_total enabled_n disabled_n known_n suite_n skip_missing_n skip_expired_n test_decl suite_decl assert_n < "$SCAN_TMP/counts"
echo "check-test-catalog:"
echo "  测试文件            $total"
echo "  缺文件头注释        $header_missing"
echo "  skip 站点           ${skip_total}（.enabled ${enabled_n} / .disabled ${disabled_n} / withKnownIssue ${known_n}）"
echo "  其中 @Suite skip    $suite_n"
echo "  skip 元数据缺失     $skip_missing_n"
echo "  skip 已过到期日     ${skip_expired_n}（今天 ${TODAY}）"
echo "  口径                有效执行 = 声明数 − skip 用例数；@Suite skip 需按套件内 @Test 展开"

# ---- ratchet 基线（docs/baselines/test-catalog-baseline.json，schema 2）----
# @Test/@Suite/断言计数与 skip 站点数都从 JSON 读取；缺文件/缺 key 直接 FAIL
# （fail-closed），避免门禁静默失效。
BASELINE="docs/baselines/test-catalog-baseline.json"
baseline_value() {
  local key="$1" line val
  line=$(grep -E "\"$key\"[[:space:]]*:[[:space:]]*[0-9]+" "$BASELINE" 2>/dev/null | head -n 1 || true)
  val=$(printf '%s' "$line" | grep -oE '[0-9]+' | head -n 1 || true)
  printf '%s' "$val"
}
if [ ! -f "$BASELINE" ]; then
  echo "check-test-catalog: FAIL 缺少基线 $BASELINE（fail-closed：基线文件必须入库）" >&2
  exit 1
fi
BASELINE_SCHEMA=$(baseline_value schema)
if [ "$BASELINE_SCHEMA" != "2" ]; then
  echo "check-test-catalog: FAIL 基线 schema 必须为 2（实测 ${BASELINE_SCHEMA:-缺失}）：$BASELINE" >&2
  exit 1
fi
BASELINE_TEST_DECL=$(baseline_value test_decl)
BASELINE_SUITE_DECL=$(baseline_value suite_decl)
BASELINE_ASSERT=$(baseline_value assert)
BASELINE_SKIP_DECL=$(baseline_value skip_decl)
baseline_missing=0
for pair in "test_decl=${BASELINE_TEST_DECL}" "suite_decl=${BASELINE_SUITE_DECL}" "assert=${BASELINE_ASSERT}" "skip_decl=${BASELINE_SKIP_DECL}"; do
  case "$pair" in
    *=) echo "check-test-catalog: FAIL 基线缺 key：metrics.${pair%=}（$BASELINE）" >&2; baseline_missing=1 ;;
  esac
done
if [ "$baseline_missing" -ne 0 ]; then
  exit 1
fi

# --write-baseline：只允许持平/收紧；同目录 mktemp + mv 原子替换，schema=2、无 generated_at。
write_baseline() {
  mkdir -p "$(dirname "$BASELINE")"
  local tmp
  tmp="$(mktemp "$(dirname "$BASELINE")/.test-catalog-baseline.XXXXXX")"
  cat > "$tmp" <<JSON
{
  "schema": 2,
  "note": "check-test-catalog ratchet：声明/断言/skip 站点基线（只降不升；--write-baseline 收紧，上涨需 --allow-growth 并记账）。",
  "metrics": {
    "test_decl": $test_decl,
    "suite_decl": $suite_decl,
    "assert": $assert_n,
    "skip_decl": $skip_total
  }
}
JSON
  chmod 644 "$tmp"
  mv "$tmp" "$BASELINE"
}

check_growth() {
  local key="$1" cur="$2" base="$3"
  if [ "$cur" -gt "$base" ]; then
    echo "  涨：$key $base -> $cur" >&2
    return 1
  fi
  return 0
}

if [ "$WRITE" -eq 1 ]; then
  grew=0
  if [ "$ALLOW_GROWTH" -eq 0 ]; then
    check_growth test_decl "$test_decl" "$BASELINE_TEST_DECL" || grew=1
    check_growth suite_decl "$suite_decl" "$BASELINE_SUITE_DECL" || grew=1
    check_growth assert "$assert_n" "$BASELINE_ASSERT" || grew=1
    check_growth skip_decl "$skip_total" "$BASELINE_SKIP_DECL" || grew=1
  fi
  if [ "$grew" -ne 0 ]; then
    echo "check-test-catalog: REFUSED — 基线膨胀必须显式批准（--allow-growth + 台账）" >&2
    exit 1
  fi
  write_baseline
  echo "check-test-catalog: baseline 已写入 $BASELINE"
  printf '  %-10s %s\n' test_decl "$test_decl"
  printf '  %-10s %s\n' suite_decl "$suite_decl"
  printf '  %-10s %s\n' assert "$assert_n"
  printf '  %-10s %s\n' skip_decl "$skip_total"
  exit 0
fi

if [ "$header_missing" -gt 0 ]; then
  echo "WARN 以下测试文件首个非空行不是 // 注释："
  sed '/^$/d; s/^/  - /' "$SCAN_TMP/missing-header.txt"
fi

if [ "$skip_missing_n" -gt 0 ]; then
  echo "WARN 以下 skip 站点缺少 owner/到期/原因（连续注释块内）："
  cat "$SCAN_TMP/warn-missing.txt"
fi

if [ "$skip_expired_n" -gt 0 ]; then
  echo "WARN 以下 skip 站点已过到期日，必须删除 gate 或重新评估（不能只续期）："
  cat "$SCAN_TMP/warn-expired.txt"
fi

# 6) 用例/套件 ratchet：删一条 @Test 或 @Suite 不会让任何用例变红，是历史空白。
#    基线按实测值钉死（docs/baselines/test-catalog-baseline.json）；新增用例只会让
#    数字变大，删用例必须 --write-baseline 显式收紧并在台账记账。
if [ -z "${test_decl:-}" ] || [ -z "${suite_decl:-}" ] || [ -z "${assert_n:-}" ]; then
  echo "check-test-catalog: FAIL 计数脚本没有输出（python3 可用？）" >&2
  exit 1
fi
ratchet_bad=0
if [ "${test_decl:-0}" -lt "$BASELINE_TEST_DECL" ]; then
  echo "FAIL @Test 声明数回落：${test_decl} < baseline ${BASELINE_TEST_DECL}（删用例必须显式下调 baseline 并记账）" >&2
  ratchet_bad=1
fi
if [ "${suite_decl:-0}" -lt "$BASELINE_SUITE_DECL" ]; then
  echo "FAIL @Suite 声明数回落：${suite_decl} < baseline ${BASELINE_SUITE_DECL}" >&2
  ratchet_bad=1
fi
echo "  用例/套件 ratchet  @Test ${test_decl}/$BASELINE_TEST_DECL · @Suite ${suite_decl}/$BASELINE_SUITE_DECL"

# 7) 断言 ratchet：只数声明拦不住"删真用例、补空壳用例"。断言数（#expect / #require）
#    才是"检查了多少事"的代理指标——把真用例删掉换成空函数，断言数会掉。
if [ "$assert_n" -lt "$BASELINE_ASSERT" ]; then
  echo "FAIL 断言数回落：$assert_n < baseline $BASELINE_ASSERT（删断言/换空壳用例必须显式下调并记账）" >&2
  ratchet_bad=1
fi
echo "  断言 ratchet        #expect+#require $assert_n/$BASELINE_ASSERT"

# 8) skip 站点 ratchet：skip 数只降不升（新增 gated 用例相当于放宽门禁，须显式批准）。
if [ "${skip_total:-0}" -gt "$BASELINE_SKIP_DECL" ]; then
  echo "FAIL skip 站点增加：${skip_total} > baseline ${BASELINE_SKIP_DECL}（新增 gated 用例必须 --write-baseline --allow-growth 并记账）" >&2
  ratchet_bad=1
fi
echo "  skip 站点 ratchet   ${skip_total}/$BASELINE_SKIP_DECL"

echo "----"
if [ "$STRICT" -eq 1 ]; then
  if [ "$header_missing" -gt 0 ] || [ "$skip_missing_n" -gt 0 ] || [ "$skip_expired_n" -gt 0 ] \
     || [ "$ratchet_bad" -ne 0 ]; then
    echo "check-test-catalog: FAILED (--strict)" >&2
    exit 1
  fi
  echo "check-test-catalog: OK (--strict)"
else
  echo "check-test-catalog: PASS (warning mode; 使用 --strict 作为硬门禁)"
fi
