#!/usr/bin/env bash
# 测试分片入口：按测试源码里的“顶层测试单元”轮转生成多个 --filter 正则，
# 串行执行每个分片并汇总耗时（macOS）；Linux 只支持 --dry-run/--help/--self-test。
#
# 单元口径（由本脚本内嵌的 Python 静态解析得出，不依赖 macOS）：
#   - scope：顶层类型声明（struct/class/actor/enum/extension）——测试 ID 形如
#     "Module.AlphaTests/test()"，嵌套类型的测试仍包含最外层类型名
#     （"Module.AlphaTests/Nested/inner()"），所以只用最外层单元名过滤即可覆盖；
#   - global：文件级自由 @Test 函数——ID 形如 "Module.freeFn()"，用 "\\.freeFn\\(" 过滤。
# 自校验：每个 @Test 声明必须归属且只归属一个单元；只要有一个没归属就报错退出，
# 绝不静默漏测（宁可分片失败也不让测试悄悄不跑）。
# 分片不足单元数、或某分片运行 0 个测试，都会明确报错。
#
# >>> usage
#   scripts/test-shard.sh core|app <shards> [--dry-run]
#   scripts/test-shard.sh --self-test
#   scripts/test-shard.sh --help
#
#   core|app    分片 desktop/native/gather-{core,app} 测试包
#   shards      分片数（>=1；必须 <= 测试单元数，否则报错）
#   --dry-run   只打印每个分片的命令与覆盖单元数，不真正运行（Linux 可验证）
#   --self-test 运行内嵌解析器自测（合成夹具；Linux/macOS 可跑）
#   环境变量: SHARD_KEEP=1 成功时也保留分片日志（默认成功即清理；失败一定保留）
# <<< usage
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    # 标记行定界（>>> usage/<<< usage），不依赖固定 sed 行号。
    sed -n '/^# >>> usage$/,/^# <<< usage$/p' "$0" \
        | sed -e '1d' -e '$d' -e 's/^# //' -e 's/^#$//'
}

die() {
    echo "test-shard.sh: $*" >&2
    exit 2
}

# 内嵌 Python（唯一实例）：inventory = 输出单元清单；self-test = 解析器自测。
run_py() {
    python3 - "$@" <<'GATHER_SHARD_PY'
"""测试单元静态清单（scripts/test-shard.sh 的 Python 部分）。

只有两种顶层单元：
  scope  —— 顶层 struct/class/actor/enum/extension 声明；其体内任意深度的 @Test
            都归属该最外层类型名（Swift Testing 的 testID 以最外层类型名开头）。
  global —— 文件级自由 @Test 函数，按函数名生成 "\\.name\\(" 过滤。
注释/字符串里的 @Test 不算；括号深度用“注释+字符串内容遮罩”后的文本统计，
避免 JSON 夹具里的花括号干扰。自校验保证没有 @Test 落在单元之外。
"""
import os
import re
import sys

# 顶层声明（masked 文本上 search；属性/修饰符在关键字前也能命中）。
SCOPE_RE = re.compile(
    r'(?:^|\s)(struct|class|actor|enum|extension)\s+([A-Za-z_][A-Za-z0-9_]*)')
TEST_RE = re.compile(r'^[ \t]*@Test\b')
FUNC_RE = re.compile(r'\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)')
GLOBAL_LOOKAHEAD = 8


def mask_source(text):
    """注释与字符串字面量内容替换为空格（保留换行），供括号深度/声明扫描。"""
    out = list(text)
    n = len(text)
    i = 0
    while i < n:
        c = text[i]
        if c == '#':
            j = i
            while j < n and text[j] == '#':
                j += 1
            if j < n and text[j] == '"':
                hashes = j - i
                if text.startswith('"""', j):
                    close = '"""' + '#' * hashes
                    k = text.find(close, j + 3)
                    end = n if k < 0 else k + len(close)
                else:
                    close = '"' + '#' * hashes
                    k = text.find(close, j + 1)
                    end = n if k < 0 else k + len(close)
                for m in range(i, end):
                    if out[m] != '\n':
                        out[m] = ' '
                i = end
                continue
            i += 1
            continue
        if c == '"':
            if text.startswith('"""', i):
                k = text.find('"""', i + 3)
                end = n if k < 0 else k + 3
            else:
                j = i + 1
                while j < n:
                    if text[j] == '\\':
                        j += 2
                        continue
                    if text[j] == '"' or text[j] == '\n':
                        j += 1
                        break
                    j += 1
                end = j
            for m in range(i, end):
                if out[m] != '\n':
                    out[m] = ' '
            i = end
            continue
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            for m in range(i, j):
                out[m] = ' '
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
            for m in range(i, min(j, n)):
                if out[m] != '\n':
                    out[m] = ' '
            i = j
            continue
        i += 1
    return ''.join(out)


def scan_file(path):
    """返回 (scope_counts, globals, unassigned, total)；unassigned 为 (file, line, 原因)。"""
    with open(path, encoding='utf-8', errors='replace') as handle:
        masked = mask_source(handle.read())
    lines = masked.splitlines()
    scope_counts = {}
    globals_ = []
    unassigned = []
    total = 0
    depth = 0
    scope = None
    index = 0
    while index < len(lines):
        line = lines[index]
        if depth == 0:
            match = SCOPE_RE.search(line)
            if match:
                scope = match.group(2)
                scope_counts.setdefault(scope, 0)
            if TEST_RE.match(line):
                total += 1
                func = FUNC_RE.search(line)
                if not func:
                    for look in range(index + 1, min(index + GLOBAL_LOOKAHEAD, len(lines))):
                        func = FUNC_RE.search(lines[look])
                        if func:
                            break
                if func:
                    globals_.append(func.group(1))
                else:
                    unassigned.append((path, index + 1, '自由 @Test 后找不到 func 名'))
        elif TEST_RE.match(line):
            total += 1
            if scope is not None:
                scope_counts[scope] += 1
            else:
                unassigned.append((path, index + 1, '不在任何顶层类型/扩展内'))
        for char in line:
            if char == '{':
                depth += 1
            elif char == '}':
                depth -= 1
                if depth == 0:
                    scope = None
            if depth < 0:
                depth = 0
        index += 1
    return scope_counts, globals_, unassigned, total


def collect(root):
    """遍历 root 下 *.swift（按路径排序），汇总单元清单与自校验数据。"""
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith('.swift'):
                files.append(os.path.join(dirpath, name))
    files.sort()
    counts = {}
    globals_ = []
    unassigned = []
    total = 0
    for path in files:
        scope_counts, file_globals, file_unassigned, file_total = scan_file(path)
        for name, count in scope_counts.items():
            counts[name] = counts.get(name, 0) + count
        globals_.extend(file_globals)
        unassigned.extend(file_unassigned)
        total += file_total
    units = [('scope', count, name) for name, count in counts.items() if count > 0]
    units.extend(('global', 1, name) for name in sorted(set(globals_)))
    units.sort(key=lambda item: (-item[1], item[2]))
    return units, sorted(set(globals_)), unassigned, total, len(files)


def inventory(root):
    """打印单元清单；任何 @Test 未归属时返回非零（不静默漏测）。"""
    units, globals_, unassigned, total, file_count = collect(root)
    assigned = sum(count for _kind, count, _name in units)
    if unassigned:
        print('test-shard: %d 个 @Test 无法归属顶层测试单元（无法安全分片）：'
              % len(unassigned), file=sys.stderr)
        for path, line, reason in unassigned[:20]:
            print('  %s:%d: %s' % (path, line, reason), file=sys.stderr)
        return 1
    if total == 0:
        print('test-shard: 在 %s 下没有找到任何 @Test 声明（%d 个 .swift）'
              % (root, file_count), file=sys.stderr)
        return 1
    if assigned != total:
        print('test-shard: 自校验失败：@Test 总数 %d，已归属 %d（差 %d）'
              % (total, assigned, total - assigned), file=sys.stderr)
        return 1
    print('  scope %d 个 / global %d 个 / @Test 总数 %d（%d 个 .swift 文件）'
          % (len(units) - len(globals_), len(globals_), total, file_count),
          file=sys.stderr)
    for kind, count, name in units:
        print('%s\t%d\t%s' % (kind, count, name))
    return 0


_SELF_TEST_FIXTURE = '''import Testing

@Suite("甲套件")
struct AlphaTests {
    @Test func one() {
        let raw = #"raw {" @Test here"#
        let multi = """
        multi { @Test line
        """
        _ = (raw, multi)
    }

    @Test(arguments: [1, 2])
    func two(x: Int) {
        #expect(x > 0)
    }

    // @Test 注释：不算
    /* @Test 块注释 { 不算 */
    struct Nested {
        @Test func inner() {}
    }
}

final class BetaTests {
    @Test func beta() throws {}
}

extension BetaTests {
    @Test func extBeta() {}
}

@Test func freeOne() {
    let brace = "}"
    _ = brace
}

@Test("显示名")
func freeTwo() {}
'''

_SELF_TEST_ORPHAN = '''import Testing

do {
    @Test func orphaned() {}
}
'''


def _self_test():
    import shutil
    import tempfile
    checks = []
    failures = []

    def check(condition, message):
        checks.append(message)
        if not condition:
            failures.append(message)

    workdir = tempfile.mkdtemp(prefix='gather-test-shard-')
    try:
        tests_root = os.path.join(workdir, 'Tests')
        os.makedirs(tests_root)
        fixture = os.path.join(tests_root, 'FixtureTests.swift')
        with open(fixture, 'w', encoding='utf-8') as handle:
            handle.write(_SELF_TEST_FIXTURE)
        units, globals_, unassigned, total, file_count = collect(tests_root)
        by_name = {name: count for kind, count, name in units if kind == 'scope'}
        check(by_name == {'AlphaTests': 3, 'BetaTests': 2},
              'scope 计数（实际 %r）' % (by_name,))
        check(globals_ == ['freeOne', 'freeTwo'], '自由函数清单（实际 %r）' % (globals_,))
        check(total == 7, '@Test 总数 = 7（实际 %d）' % total)
        check(not unassigned, '没有未归属 @Test（实际 %r）' % (unassigned,))
        check(file_count == 1, '.swift 文件计数（实际 %d）' % file_count)

        # 过滤正则：每个 testID 恰好命中一个单元；嵌套类型名单独过滤命中 0。
        alternatives = []
        for kind, _count, name in units:
            if kind == 'scope':
                alternatives.append(r'\.' + name + '/')
            else:
                alternatives.append(r'\.' + name + r'\(')
        sample_ids = [
            'Pkg.AlphaTests/one()/FixtureTests.swift:4:6',
            'Pkg.AlphaTests/two(x:)/FixtureTests.swift:14:6',
            'Pkg.AlphaTests/Nested/inner()/FixtureTests.swift:24:10',
            'Pkg.BetaTests/beta()/FixtureTests.swift:31:6',
            'Pkg.BetaTests/extBeta()/FixtureTests.swift:35:6',
            'Pkg.freeOne()/FixtureTests.swift:39:2',
            'Pkg.freeTwo()/FixtureTests.swift:44:2',
        ]
        for test_id in sample_ids:
            hits = [alt for alt in alternatives if re.search(alt, test_id)]
            check(len(hits) == 1, 'testID %r 恰好命中 1 个分片（实际 %r）'
                  % (test_id, hits))
        check(not re.search(r'\.Nested/', 'Pkg.AlphaTests/Nested/inner()/x.swift:1:1'),
              '嵌套类型名单独过滤不命中（必须按最外层单元名分片）')

        orphan_root = os.path.join(workdir, 'Orphan')
        os.makedirs(orphan_root)
        orphan_file = os.path.join(orphan_root, 'Orphan.swift')
        with open(orphan_file, 'w', encoding='utf-8') as handle:
            handle.write(_SELF_TEST_ORPHAN)
        _units, _globals, orphan_unassigned, orphan_total, _files = collect(orphan_root)
        check(orphan_total == 1 and len(orphan_unassigned) == 1,
              '未归属 @Test 被识别（total=%d, unassigned=%r）'
              % (orphan_total, orphan_unassigned))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if failures:
        print('test-shard 解析器自测失败（%d/%d 项）：'
              % (len(failures), len(checks)), file=sys.stderr)
        for failure in failures:
            print('  - ' + failure, file=sys.stderr)
        return 1
    print('test-shard 解析器自测: OK（%d 项断言）' % len(checks))
    return 0


def main(argv):
    if not argv:
        print('test-shard: 缺少模式（inventory|self-test）', file=sys.stderr)
        return 2
    mode = argv[0]
    if mode == 'inventory':
        if len(argv) != 2:
            print('test-shard: inventory 需要 1 个参数（测试根目录）', file=sys.stderr)
            return 2
        return inventory(argv[1])
    if mode == 'self-test':
        return _self_test()
    print('test-shard: 未知模式 %r（inventory|self-test）' % (mode,), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
GATHER_SHARD_PY
}

TARGET=""
SHARDS=""
DRY_RUN=0
SELF_TEST=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --self-test) SELF_TEST=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "未知选项 $1（--help 查看用法）" ;;
        *)
            if [ -z "$TARGET" ]; then
                TARGET="$1"
            elif [ -z "$SHARDS" ]; then
                SHARDS="$1"
            else
                die "多余参数 $1（用法：core|app <shards>）"
            fi
            shift
            ;;
    esac
done
[ "$#" -eq 0 ] || die "多余参数：$*"

command -v python3 >/dev/null 2>&1 || die "缺少 python3（静态单元解析需要）"

if [ "$SELF_TEST" = 1 ]; then
    run_py self-test
    exit 0
fi

case "$TARGET" in
    core)
        PKG="$ROOT/desktop/native/gather-core"
        TESTS_ROOT="$PKG/Tests/GatherCoreTests"
        ;;
    app)
        PKG="$ROOT/desktop/native/gather-app"
        TESTS_ROOT="$PKG/Tests/GatherAppTests"
        ;;
    *) die "未知目标 ${TARGET:-<空>}（core|app）" ;;
esac
case "$SHARDS" in
    ''|*[!0-9]*) die "shards 必须是正整数（当前 '${SHARDS:-<空>}'）" ;;
esac
[ "$SHARDS" -gt 0 ] || die "shards 必须是正整数（当前 '$SHARDS'）"
[ -d "$TESTS_ROOT" ] || die "测试目录不存在: $TESTS_ROOT"

# 非 --dry-run 先做平台闸门：Linux 无 macOS SDK，直接报错退出 2，
# 不做后面的源码扫描（省 1s，也避免“扫描成功但无法运行”的误导）。
if [ "$DRY_RUN" != 1 ] && [ "$(uname -s)" != "Darwin" ]; then
    echo "test-shard.sh: 真实分片运行需要 macOS（swift test 需要 macOS SDK；本机 Linux 无）" >&2
    echo "  Linux 可用：--dry-run（分片命令）/ --help / --self-test（解析器自测）" >&2
    exit 2
fi

# 静态单元清单（stdout 为 kind<TAB>count<TAB>name；诊断在 stderr）。
# 解析器自校验失败（存在未归属 @Test）时直接终止，绝不静默少跑测试。
if ! UNITS="$(run_py inventory "$TESTS_ROOT")"; then
    echo "test-shard.sh: 测试单元解析失败（见上方诊断）；为避免漏测，停止分片" >&2
    exit 1
fi

UNIT_KIND=()
UNIT_COUNT=()
UNIT_NAME=()
while IFS=$'\t' read -r unit_kind unit_count unit_name; do
    [ -n "${unit_kind:-}" ] || continue
    UNIT_KIND+=("$unit_kind")
    UNIT_COUNT+=("$unit_count")
    UNIT_NAME+=("$unit_name")
done <<< "$UNITS"

N=${#UNIT_NAME[@]}
[ "$N" -gt 0 ] || die "测试单元数为 0（解析器应已报错）"
[ "$N" -ge "$SHARDS" ] || die "测试单元数 $N 少于 shards $SHARDS：无法保证每个分片非空（请减小 shards 或补测试）"

TYPE_COUNT=0
GLOBAL_COUNT=0
TOTAL_TESTS=0
index=0
while [ "$index" -lt "$N" ]; do
    case "${UNIT_KIND[$index]}" in
        scope) TYPE_COUNT=$((TYPE_COUNT + 1)) ;;
        global) GLOBAL_COUNT=$((GLOBAL_COUNT + 1)) ;;
    esac
    TOTAL_TESTS=$((TOTAL_TESTS + ${UNIT_COUNT[$index]}))
    index=$((index + 1))
done

# 轮转分配：inventory 已按 @Test 计数从多到少排序，顺序取模即可兼顾均衡。
shard=0
SHARD_ALT=()
SHARD_UNITS=()
SHARD_TESTS=()
while [ "$shard" -lt "$SHARDS" ]; do
    SHARD_ALT[$shard]=""
    SHARD_UNITS[$shard]=0
    SHARD_TESTS[$shard]=0
    shard=$((shard + 1))
done
index=0
while [ "$index" -lt "$N" ]; do
    shard=$((index % SHARDS))
    if [ "${UNIT_KIND[$index]}" = "scope" ]; then
        ALT="\\.${UNIT_NAME[$index]}/"
    else
        ALT="\\.${UNIT_NAME[$index]}\\("
    fi
    if [ -z "${SHARD_ALT[$shard]}" ]; then
        SHARD_ALT[$shard]="$ALT"
    else
        SHARD_ALT[$shard]="${SHARD_ALT[$shard]}|$ALT"
    fi
    SHARD_UNITS[$shard]=$(( ${SHARD_UNITS[$shard]} + 1 ))
    SHARD_TESTS[$shard]=$(( ${SHARD_TESTS[$shard]} + ${UNIT_COUNT[$index]} ))
    index=$((index + 1))
done

if [ "$DRY_RUN" = 1 ]; then
    echo "== test-shard.sh --dry-run（不执行；Linux 可验证分片）=="
    echo "目标: $TARGET（$PKG）"
    echo "测试根: $TESTS_ROOT"
    echo "单元: $N 个（顶层套件类型 $TYPE_COUNT 个 / 自由 @Test 函数 $GLOBAL_COUNT 个）；@Test 声明 $TOTAL_TESTS 个"
    echo "分片: $SHARDS 片（按 @Test 计数从多到少轮转；每片一个 --filter 正则）"
    shard=0
    while [ "$shard" -lt "$SHARDS" ]; do
        echo ""
        echo "shard $((shard + 1))/$SHARDS：覆盖单元 ${SHARD_UNITS[$shard]} 个 / @Test ${SHARD_TESTS[$shard]} 个"
        printf "  swift test --package-path %s --filter '%s'\n" \
            "$PKG" "${SHARD_ALT[$shard]}"
        shard=$((shard + 1))
    done
    exit 0
fi

# 真实运行（平台闸门已在前面通过）：swift 就绪即可。
command -v swift >/dev/null 2>&1 \
    || die "缺少 swift（macOS 需安装 Xcode 或 Command Line Tools）"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gather-shard-XXXXXX")"
KEEP=0
cleanup() {
    if [ "$KEEP" = 1 ] || [ "${SHARD_KEEP:-0}" = "1" ]; then
        echo "分片日志保留: $WORK（清理：rm -rf $WORK）" >&2
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

echo "== gather-$TARGET 测试分片：$SHARDS 片 / $N 个单元 / $TOTAL_TESTS 个 @Test =="
echo "   目标包: $PKG"
echo "   日志目录: $WORK"
FAILED=0
TOTAL_SECONDS=0
SHARD_STATUS=()
SHARD_DUR=()
SHARD_RAN=()
shard=0
while [ "$shard" -lt "$SHARDS" ]; do
    LOG="$WORK/shard-$((shard + 1)).log"
    echo ""
    echo "== shard $((shard + 1))/$SHARDS（单元 ${SHARD_UNITS[$shard]} 个 / @Test ${SHARD_TESTS[$shard]} 个）"
    STARTED_AT=$(date +%s)
    if swift test --package-path "$PKG" \
        --explicit-target-dependency-import-check error \
        --filter "${SHARD_ALT[$shard]}" >"$LOG" 2>&1; then
        RC=0
    else
        RC=$?
    fi
    FINISHED_AT=$(date +%s)
    DUR=$((FINISHED_AT - STARTED_AT))
    TOTAL_SECONDS=$((TOTAL_SECONDS + DUR))
    RAN="$(grep -Eo 'Test run with [0-9]+ tests?' "$LOG" 2>/dev/null \
        | tail -1 | grep -Eo '[0-9]+' || true)"
    SHARD_STATUS[$shard]="OK"
    if [ "$RC" -ne 0 ]; then
        SHARD_STATUS[$shard]="FAIL(exit $RC)"
        FAILED=1
    elif [ -z "${RAN:-}" ]; then
        SHARD_STATUS[$shard]="FAIL(无测试汇总行)"
        FAILED=1
    elif [ "$RAN" = "0" ]; then
        # swift-testing 过滤到 0 个测试时退出码仍是 0；分片 0 测试视为失败，
        # 否则过滤正则失效会静默“跑过”。
        SHARD_STATUS[$shard]="FAIL(0 测试命中)"
        FAILED=1
    fi
    SHARD_DUR[$shard]=$DUR
    SHARD_RAN[$shard]="${RAN:-?}"
    echo "   ${SHARD_STATUS[$shard]}，耗时 ${DUR}s，@Test ${SHARD_RAN[$shard]}（日志 $LOG）"
    if [ "${SHARD_STATUS[$shard]}" != "OK" ]; then
        grep -nE '✘|recorded an issue|^error:' "$LOG" | head -20 >&2 || true
        echo "   日志尾部（最多 60 行）：" >&2
        tail -60 "$LOG" >&2
    fi
    shard=$((shard + 1))
done

echo ""
echo "== 分片结果（串行合计 ${TOTAL_SECONDS}s）=="
shard=0
while [ "$shard" -lt "$SHARDS" ]; do
    printf "  shard %d/%d  %-18s %5ds  @Test %s\n" \
        "$((shard + 1))" "$SHARDS" "${SHARD_STATUS[$shard]}" \
        "${SHARD_DUR[$shard]}" "${SHARD_RAN[$shard]}"
    shard=$((shard + 1))
done
if [ "$FAILED" -ne 0 ]; then
    KEEP=1
    echo "test-shard.sh: 有分片失败（日志保留在 $WORK）" >&2
    exit 1
fi
echo "全部分片通过（$SHARDS 片，合计 ${TOTAL_SECONDS}s）"
